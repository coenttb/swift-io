//
//  IO.Executor.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 24/12/2025.
//

import Synchronization

extension IO.Executor {
    /// The executor pool for async I/O operations.
    ///
    /// ## Design
    /// The pool delegates blocking syscalls to a `Lane` (default: `Threads` lane).
    /// This design provides:
    /// - Dedicated threads for blocking I/O (no starvation of cooperative pool)
    /// - Bounded queue with configurable backpressure
    /// - Deterministic shutdown semantics
    ///
    /// ## Lifecycle
    /// - Custom pools must call `shutdown()` when done
    ///
    /// ## Handle Management
    /// The pool owns all handles in an actor-isolated registry.
    /// Handles are accessed via transactions that provide exclusive access.
    /// Only IDs cross await boundaries; handles never escape the actor.
    ///
    /// ## Generic over Resource
    /// The pool is generic over `Resource: ~Copyable & Sendable`.
    /// This allows reuse for files, sockets, database connections, etc.
    ///
    /// ## Executor Pinning
    /// Each Pool runs on a dedicated executor thread from a shared sharded pool.
    /// This provides predictable scheduling and avoids interference with Swift's
    /// cooperative thread pool.
    ///
    /// ## Execution Model Invariants
    /// - **Actor pinning**: All actor-isolated state transitions run on the assigned executor
    /// - **Executor lifetime**: The executor must outlive the actor (`UnownedSerialExecutor`
    ///   does not retain). The shared executor pool outlives any Pool instance.
    /// - **Lane separation**: The Lane handles blocking syscalls only. Actor work (state
    ///   transitions, waiter management, continuation resumes) never goes through the Lane.
    /// - **Nonisolated fast path**: `run()` bypasses actor isolation via atomic lifecycle check,
    ///   eliminating actor hops for stateless blocking operations.
    /// - **Handle isolation**: `transaction()` remains actor-isolated for handle registry access.
    public actor Pool<Resource: ~Copyable & Sendable> {
        /// The executor this pool runs on.
        ///
        /// INVARIANT: Immutable for the lifetime of this actor. Rebinding is forbidden.
        /// `UnownedSerialExecutor` does not retain; executor must outlive actor.
        private let _executor: IO.Executor.Thread

        /// The lane for executing blocking operations.
        public let lane: IO.Blocking.Lane

        /// Unique scope identifier for this executor instance.
        public nonisolated let scope: UInt64

        /// The shard index when used in a `Shards` collection.
        ///
        /// For standalone pools, this is always 0.
        public nonisolated let shardIndex: UInt16

        /// Atomic lifecycle state for nonisolated access.
        ///
        /// This enables `run()` to bypass actor isolation by checking lifecycle
        /// atomically. Memory ordering:
        /// - `run()` reads with `.acquiring` to see effects of shutdown
        /// - `shutdown()` transitions with `.releasing` to publish state change
        private nonisolated let _lifecycle: Atomic<IO.Lifecycle>

        /// Maximum waiters per handle (from backpressure policy).
        private let handleWaitersLimit: Int

        /// Teardown policy for resource cleanup during shutdown.
        private let teardown: IO.Executor.Teardown<Resource>

        /// Counter for generating unique handle IDs.
        private var nextRawID: UInt64 = 0

        /// Actor-owned handle registry.
        /// Each entry holds a Resource (or nil if checked out) plus waiters.
        private var handles: [IO.Handle.ID: IO.Executor.Handle.Entry<Resource>] = [:]

        /// Returns the executor this actor runs on.
        ///
        /// This pins the actor to a specific executor thread from the shared pool,
        /// ensuring predictable scheduling behavior.
        ///
        /// Note: Must be in actor body (not extension) for Actor protocol conformance
        /// with ~Copyable generic parameter.
        public nonisolated var unownedExecutor: UnownedSerialExecutor {
            _executor.asUnownedSerialExecutor()
        }

        /// Creates an executor with the given lane and backpressure policy.
        ///
        /// Uses round-robin assignment to select an executor from the shared pool.
        ///
        /// Executors created with this initializer **must** be shut down
        /// when no longer needed using `shutdown()`.
        ///
        /// - Parameters:
        ///   - lane: The lane for executing blocking operations.
        ///   - policy: Backpressure policy (default: `.default`).
        ///   - teardown: Teardown policy for resource cleanup (default: `.none`).
        ///   - shardIndex: Shard index for use in `Shards` (default: 0).
        public init(
            lane: IO.Blocking.Lane,
            policy: IO.Backpressure.Policy = .default,
            teardown: IO.Executor.Teardown<Resource> = IO.Executor.Teardown<Resource>.none,
            shardIndex: UInt16 = 0
        ) {
            self._executor = IO.Executor.shared.next()
            self.lane = lane
            self._lifecycle = Atomic(.running)
            self.handleWaitersLimit = policy.handleWaitersLimit
            self.teardown = teardown
            self.scope = IO.Executor.scopeCounter.next()
            self.shardIndex = shardIndex
        }

        /// Creates an executor with the given lane, policy, and explicit executor.
        ///
        /// Use this initializer when you need explicit control over which executor
        /// thread the pool runs on.
        ///
        /// - Parameters:
        ///   - lane: The lane for executing blocking operations.
        ///   - policy: Backpressure policy (default: `.default`).
        ///   - teardown: Teardown policy for resource cleanup (default: `.none`).
        ///   - executor: The executor thread to run on.
        ///   - shardIndex: Shard index for use in `Shards` (default: 0).
        public init(
            lane: IO.Blocking.Lane,
            policy: IO.Backpressure.Policy = .default,
            teardown: IO.Executor.Teardown<Resource> = IO.Executor.Teardown<Resource>.none,
            executor: IO.Executor.Thread,
            shardIndex: UInt16 = 0
        ) {
            self._executor = executor
            self.lane = lane
            self._lifecycle = Atomic(.running)
            self.handleWaitersLimit = policy.handleWaitersLimit
            self.teardown = teardown
            self.scope = IO.Executor.scopeCounter.next()
            self.shardIndex = shardIndex
        }

        /// Creates an executor with default Threads lane options.
        ///
        /// Uses round-robin assignment to select an executor from the shared pool.
        ///
        /// This is a convenience initializer equivalent to:
        /// ```swift
        /// Executor(lane: .threads(options), policy: options.policy, teardown: teardown)
        /// ```
        ///
        /// - Parameters:
        ///   - options: Options for the Threads lane.
        ///   - teardown: Teardown policy for resource cleanup (default: `.none`).
        public init(
            _ options: IO.Blocking.Threads.Options = .init(),
            teardown: IO.Executor.Teardown<Resource> = IO.Executor.Teardown<Resource>.none
        ) {
            self._executor = IO.Executor.shared.next()
            self.lane = .threads(options)
            self._lifecycle = Atomic(.running)
            self.handleWaitersLimit = options.policy.handleWaitersLimit
            self.teardown = teardown
            self.scope = IO.Executor.scopeCounter.next()
            self.shardIndex = 0
        }
    }
}

// MARK: - Submission Gate

extension IO.Executor.Pool where Resource: ~Copyable {
    /// Check if the pool is accepting work (actor-isolated path).
    ///
    /// Used by `register()` and `transaction()` which need actor isolation anyway.
    fileprivate var isAcceptingWork: Bool {
        _lifecycle.load(ordering: .acquiring) == .running
    }
}

// MARK: - Custom Executor

extension IO.Executor.Pool where Resource: ~Copyable {
    /// The executor this pool runs on.
    ///
    /// Use with `withTaskExecutorPreference` to keep related work co-located
    /// on the same executor shard, reducing scheduling overhead.
    public nonisolated var executor: IO.Executor.Thread {
        _executor
    }

    /// Execute work with preference for this pool's executor.
    ///
    /// This is a convenience wrapper around `withTaskExecutorPreference`.
    /// Use it to ensure Tasks created within the closure prefer this pool's
    /// executor, keeping related work co-located and reducing scheduling overhead.
    ///
    /// ## Usage
    /// ```swift
    /// await pool.withExecutorPreference {
    ///     // Tasks created here will prefer pool's executor
    ///     await doWork()
    /// }
    /// ```
    ///
    /// - Parameter body: The async work to execute.
    /// - Returns: The result of the body closure.
    public nonisolated func withExecutorPreference<T: Sendable>(
        _ body: @Sendable () async throws -> T
    ) async rethrows -> T {
        try await withTaskExecutorPreference(_executor, operation: body)
    }
}

// MARK: - Execution

extension IO.Executor.Pool where Resource: ~Copyable {
    /// Execute a blocking operation on the lane with typed throws.
    ///
    /// This method preserves the operation's specific error type while also
    /// capturing I/O infrastructure errors in `IO.Lifecycle.Error<IO.Error<E>>`.
    ///
    /// ## Performance
    /// This method is `nonisolated` and bypasses the actor hop by checking
    /// lifecycle state atomically. This eliminates 2+ actor hops per operation,
    /// significantly improving throughput for stateless blocking work.
    ///
    /// ## Cancellation Semantics
    /// - Cancellation before acceptance → `.cancelled`
    /// - Cancellation after acceptance → operation completes, then `.cancelled`
    ///
    /// - Parameter operation: The blocking operation to execute.
    /// - Returns: The result of the operation.
    /// - Throws: `IO.Lifecycle.Error<IO.Error<E>>` with lifecycle or operation errors.
    public nonisolated func run<T: Sendable, E: Swift.Error & Sendable>(
        _ operation: @Sendable @escaping () throws(E) -> T
    ) async throws(IO.Lifecycle.Error<IO.Error<E>>) -> T {
        try await run(deadline: nil, operation)
    }

    /// Execute a blocking operation on the lane with optional deadline.
    ///
    /// This method preserves the operation's specific error type while also
    /// capturing I/O infrastructure errors in `IO.Lifecycle.Error<IO.Error<E>>`.
    ///
    /// ## Performance
    /// This method is `nonisolated` and bypasses the actor hop by checking
    /// lifecycle state atomically. This eliminates 2+ actor hops per operation,
    /// significantly improving throughput for stateless blocking work.
    ///
    /// ## Cancellation Semantics
    /// - Cancellation before acceptance → `.cancelled`
    /// - Cancellation after acceptance → operation completes, then `.cancelled`
    ///
    /// - Parameters:
    ///   - deadline: Optional deadline for acceptance into the lane.
    ///   - operation: The blocking operation to execute.
    /// - Returns: The result of the operation.
    /// - Throws: `IO.Lifecycle.Error<IO.Error<E>>` with lifecycle or operation errors.
    public nonisolated func run<T: Sendable, E: Swift.Error & Sendable>(
        deadline: IO.Blocking.Deadline?,
        _ operation: @Sendable @escaping () throws(E) -> T
    ) async throws(IO.Lifecycle.Error<IO.Error<E>>) -> T {
        // Check lifecycle atomically - no actor hop required
        guard _lifecycle.load(ordering: .acquiring) == .running else {
            throw .shutdownInProgress
        }

        // Fast-path: if already cancelled, skip lane submission entirely
        if Task.isCancelled {
            throw .cancelled
        }

        // Lane.run throws(Failure) and returns Result<T, E>
        // Lane is Sendable and accessed via nonisolated let - safe for direct access
        let result: Result<T, E>
        do {
            result = try await lane.run(deadline: deadline, operation)
        } catch {
            throw IO.Lifecycle.Error(error)
        }
        switch result {
        case .success(let value):
            return value
        case .failure(let error):
            throw .failure(.leaf(error))
        }
    }
}

// MARK: - Shutdown

extension IO.Executor.Pool where Resource: ~Copyable {
    /// Shut down the executor.
    ///
    /// ## Shutdown Sequence
    /// 1. Atomically transition to `shutdownInProgress` (rejects new submissions)
    /// 2. Resume all waiters so they can observe shutdown
    /// 3. Run teardown on lane for each registered resource (exactly once, unordered)
    /// 4. Clear the registry
    /// 5. Shutdown the lane
    /// 6. Mark lifecycle as `shutdownComplete`
    ///
    /// Teardown is best-effort: lane failures during teardown are swallowed.
    public func shutdown() async {
        // 1. Atomically transition to shutdownInProgress
        let (exchanged, _) = _lifecycle.compareExchange(
            expected: .running,
            desired: .shutdownInProgress,
            ordering: .releasing
        )
        guard exchanged else { return }  // Already shutting down or shut down

        // 2. Resume all waiters so they can observe shutdown
        for (_, entry) in handles {
            entry.waiters.resumeAll()
            entry.state = .destroyed
        }

        // 3. Run teardown for each resource on the lane
        // Use IO.Handoff.Cell to move ~Copyable resources through escaping closure.
        // Cell is a one-shot ownership transfer: resource moved in, token crosses boundary, taken out.
        if let action = teardown.action {
            for (_, entry) in handles {
                if let resource = entry.take() {
                    let cell = IO.Handoff.Cell(resource)
                    let token = cell.token()
                    do {
                        let _: Void = try await lane.run(deadline: nil) {
                            let r = token.take()
                            action(r)
                        }
                    } catch {
                        // Lane refused during shutdown - token was not consumed.
                        // Cell's deinit will clean up the value.
                        // Note: This means teardown action won't run on lane, but
                        // the resource will still be cleaned up via deinit.
                    }
                }
            }
        }

        // 4. Clear the registry
        handles.removeAll()

        // 5. Shutdown the lane
        await lane.shutdown()

        // 6. Mark shutdown complete
        _lifecycle.store(.shutdownComplete, ordering: .releasing)
    }
}

// MARK: - Handle ID Generation

extension IO.Executor.Pool where Resource: ~Copyable {
    /// Generate a unique handle ID.
    private func generateHandleID() -> IO.Handle.ID {
        let raw = nextRawID
        nextRawID += 1
        return IO.Handle.ID(raw: raw, scope: scope, shard: shardIndex)
    }
}

// MARK: - Handle Registration

extension IO.Executor.Pool where Resource: ~Copyable {
    /// Register a resource and return its ID.
    ///
    /// - Parameter resource: The resource to register (ownership transferred).
    /// - Returns: A unique handle ID for future operations.
    /// - Throws: `IO.Lifecycle.Error.shutdownInProgress` if executor is shut down.
    public func register(
        _ resource: consuming Resource
    ) throws(IO.Lifecycle.Error<IO.Handle.Error>) -> IO.Handle.ID {
        guard isAcceptingWork else {
            throw .shutdownInProgress
        }
        let id = generateHandleID()
        handles[id] = IO.Executor.Handle.Entry(
            handle: resource,
            waitersCapacity: handleWaitersLimit
        )
        return id
    }

    // MARK: - Two-Phase Registration (Internal)

    /// Reserve a handle ID for later commit.
    ///
    /// This is phase 1 of two-phase registration. Call before lane work.
    /// Creates a placeholder entry in `pendingRegistration` state.
    ///
    /// - Returns: Reserved ID, or nil if shutdown in progress.
    @usableFromInline
    func _reserveHandle() -> IO.Handle.ID? {
        guard isAcceptingWork else { return nil }
        let id = generateHandleID()
        // Create placeholder entry - makes reservation observable
        handles[id] = IO.Executor.Handle.Entry(
            pendingRegistration: handleWaitersLimit
        )
        return id
    }

    /// Commit a resource to a reserved handle ID.
    ///
    /// This is phase 2 of two-phase registration. Call after lane work succeeds.
    /// If shutdown started between reserve and commit, returns the resource back
    /// so caller can run teardown.
    ///
    /// - Parameters:
    ///   - id: The reserved ID from `_reserveHandle()`.
    ///   - resource: The resource to commit (ownership transferred on success).
    /// - Returns: `nil` if committed successfully, or the resource back if shutdown started.
    @usableFromInline
    func _commitHandle(
        _ id: IO.Handle.ID,
        _ resource: consuming Resource
    ) -> Resource? {
        // Validate the reservation exists and is pending
        guard let entry = handles[id] else {
            preconditionFailure("_commitHandle: no entry for reserved ID - internal invariant violated")
        }
        precondition(entry.isPendingRegistration, "_commitHandle: entry not pending - internal invariant violated")

        guard isAcceptingWork else {
            // Shutdown started - remove pending entry, return resource for teardown
            handles.removeValue(forKey: id)
            return resource
        }

        // Commit: transition pendingRegistration → present
        entry.commitRegistration(resource)
        return nil
    }

    /// Abort a pending registration.
    ///
    /// Called when lane work fails or is cancelled before commit.
    /// Removes the placeholder entry.
    ///
    /// - Parameter id: The reserved ID from `_reserveHandle()`.
    @usableFromInline
    func _abortReservation(_ id: IO.Handle.ID) {
        guard let entry = handles[id] else { return }
        precondition(entry.isPendingRegistration, "_abortReservation: entry not pending")
        handles.removeValue(forKey: id)
    }

    /// Register a resource created on the lane.
    ///
    /// This convenience combines lane execution + `register` with proper cancellation
    /// and shutdown safety: if registration fails after creation, teardown
    /// is run automatically.
    ///
    /// ## Usage
    /// ```swift
    /// let id = try await pool.register {
    ///     try File.Handle.open(path, mode: .read)
    /// }
    /// ```
    ///
    /// ## Implementation
    /// Uses two-phase registration (reserve → create → commit) to ensure:
    /// 1. If creation fails, no resource to teardown
    /// 2. If commit fails (shutdown), we still own the resource → teardown runs
    ///
    /// Uses `IO.Handoff.Storage` to pass ~Copyable resource through escaping lane closure.
    ///
    /// - Parameters:
    ///   - deadline: Optional deadline for the creation operation.
    ///   - make: Closure that creates the resource (runs on the lane).
    /// - Returns: A unique handle ID for future operations.
    /// - Throws: `IO.Lifecycle.Error<IO.Error<E>>` on creation or registration failure.
    public func register<E: Swift.Error & Sendable>(
        deadline: IO.Blocking.Deadline? = nil,
        _ make: @Sendable @escaping () throws(E) -> Resource
    ) async throws(IO.Lifecycle.Error<IO.Error<E>>) -> IO.Handle.ID {
        // Phase 1: Reserve handle ID (actor-isolated, creates pending entry)
        guard let reservedID = _reserveHandle() else {
            throw .shutdownInProgress
        }

        // Fast-path: if already cancelled, abort reservation and skip lane submission
        if Task.isCancelled {
            _abortReservation(reservedID)
            throw .cancelled
        }

        // Create resource on lane via IO.Handoff.Storage (Resource is ~Copyable).
        // Storage stays here; token crosses the escaping boundary.
        let storage = IO.Handoff.Storage<Resource>()
        let storeToken = storage.token

        // Run make() on lane, store result via token
        let laneResult: Result<Void, E>
        do {
            laneResult = try await lane.run(deadline: deadline) {
                () throws(E) in
                let resource = try make()
                storeToken.store(resource)
            }
        } catch let laneError {
            // Lane infrastructure failure - abort reservation, storage is empty
            _abortReservation(reservedID)
            _ = storage.takeIfStored()
            throw IO.Lifecycle.Error(laneError)
        }

        // Check make() result
        switch laneResult {
        case .success:
            break
        case .failure(let error):
            // make() failed - abort reservation, storage is empty
            _abortReservation(reservedID)
            _ = storage.takeIfStored()
            throw .failure(.leaf(error))
        }

        // Take resource from storage - we now own it
        let resource = storage.take()

        // Phase 2: Commit resource to reserved ID
        // If shutdown started, _commitHandle returns the resource back for teardown
        if let resource = _commitHandle(reservedID, resource) {
            // Commit failed (shutdown started) - run teardown with returned resource
            if let action = teardown.action {
                let cell = IO.Handoff.Cell(resource)
                let token = cell.token()
                do {
                    // Try to run teardown on lane
                    try await lane.run(deadline: nil) {
                        let r = token.take()
                        action(r)
                    }
                } catch {
                    // Lane refused (shutdown) - Cell's deinit handles cleanup
                }
            }
            throw .shutdownInProgress
        }

        return reservedID
    }
}

// MARK: - Handle Validation

extension IO.Executor.Pool where Resource: ~Copyable {
    /// Check if a handle ID is currently valid.
    ///
    /// - Parameter id: The handle ID to check.
    /// - Returns: `true` if the handle exists and is not destroyed.
    public func isValid(_ id: IO.Handle.ID) -> Bool {
        guard let entry = handles[id] else { return false }
        return entry.state != .destroyed
    }

    /// Check if a handle ID refers to an open handle.
    ///
    /// This is the source of truth for handle liveness. Returns true if:
    /// - The ID belongs to this executor (scope match)
    /// - An entry exists in the registry
    /// - The entry is present or checked out (not destroyed)
    ///
    /// - Parameter id: The handle ID to check.
    /// - Returns: `true` if the handle is logically open.
    public func isOpen(_ id: IO.Handle.ID) -> Bool {
        guard id.scope == scope else { return false }
        guard let entry = handles[id] else { return false }
        return entry.isOpen
    }
}

// MARK: - Waiter Parking

extension IO.Executor.Pool where Resource: ~Copyable {
    /// Arms `waiter`, enqueues it, then suspends until resumed by `_checkInHandle`.
    ///
    /// This method is actor-isolated and is the only place that may mutate
    /// `entry.waiters` as part of the wait path. It exists to ensure the
    /// enqueue happens on the actor executor even when the caller is inside
    /// an escaping `@Sendable` cancellation handler operation.
    ///
    /// - Returns: `true` if enqueued, `nil` if entry not found, `false` if queue was full.
    private func _park(
        _ waiter: IO.Handle.Waiter,
        for id: IO.Handle.ID
    ) async -> Bool? {
        // Look up entry inside actor-isolated method to avoid Sendable issues
        guard let entry = handles[id] else {
            return nil
        }

        var enqueued = true

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            // Debug guard wraps only the synchronous mutation, not the suspension
            #if DEBUG
                entry._debugBeginMutation()
                defer { entry._debugEndMutation() }
            #endif

            let didArm = waiter.arm(continuation: continuation)
            precondition(didArm, "Waiter \(waiter.token) failed to arm exactly once")

            if !entry.waiters.enqueue(waiter) {
                enqueued = false

                // Ensure the task does not hang if we fail to enqueue after installing a continuation.
                if let result = waiter.takeForResume() {
                    result.continuation.resume()
                } else {
                    continuation.resume()
                }
            }
        }

        return enqueued
    }
}

// MARK: - Transaction API

extension IO.Executor.Pool where Resource: ~Copyable {
    /// Execute a transaction with exclusive handle access and typed errors.
    ///
    /// ## Semantics
    /// Transaction does not imply database-style atomicity or rollback:
    /// - Exclusive access to the resource (mutual exclusion)
    /// - Guaranteed check-in after body completes (including errors/cancellation)
    /// - No rollback or atomic commit semantics are implied
    ///
    /// ## Cancellation Semantics
    ///
    /// - `onCancel` handler only flips a cancelled bit synchronously (no Task, no resume)
    /// - Cancelled waiters wake, observe `wasCancelled`, and throw `.cancelled`
    /// - Cancellation after checkout: lane operation completes (if guaranteed),
    ///   handle is checked in, then `.cancelled` is thrown
    ///
    /// ## Algorithm
    /// 1. Validate scope and existence
    /// 2. If handle available: move out (entry.handle = nil)
    /// 3. Else: enqueue waiter and suspend (cancellation-safe)
    /// 4. Execute via slot: allocate slot, run on lane, move handle back
    /// 5. Check-in: restore handle or close if destroyed
    /// 6. Resume next non-cancelled waiter
    ///
    /// INVARIANT: All continuation resumption happens on the actor executor.
    /// The actor drains cancelled waiters during resumeNext() (on handle check-in).
    /// No continuations are resumed from `onCancel` or while holding locks.
    public func transaction<T: Sendable, E: Swift.Error & Sendable>(
        _ id: IO.Handle.ID,
        _ body: @Sendable @escaping (inout Resource) throws(E) -> T
    ) async throws(IO.Lifecycle.Error<IO.Executor.Transaction.Error<E>>) -> T {
        // Submission gate: reject immediately if shutdown
        guard isAcceptingWork else {
            throw .shutdownInProgress
        }

        // Step 1: Validate scope
        guard id.scope == scope else {
            throw .failure(.handle(.scopeMismatch))
        }

        // Step 2: Checkout handle (with waiting if needed)
        guard let entry = handles[id] else {
            throw .failure(.handle(.invalidID))
        }

        if entry.state == .destroyed {
            throw .failure(.handle(.invalidID))
        }

        // If handle is available, take it
        var checkedOutHandle: Resource
        if entry.state == .present, let h = entry.take() {
            entry.state = .checkedOut
            checkedOutHandle = h
        } else {
            // Step 3: Handle is checked out - wait for it
            // Check if waiter queue has capacity
            if entry.waiters.isFull {
                throw .failure(.handle(.waitersFull))
            }

            // Fast-path: if already cancelled, skip waiter machinery entirely
            // This avoids the cost of continuation setup + cancellation handler
            // for tasks that are already cancelled before waiting
            if Task.isCancelled {
                throw .cancelled
            }

            let token = entry.waiters.generateToken()
            let waiter = IO.Handle.Waiter(token: token)

            let enqueued = await withTaskCancellationHandler {
                await self._park(waiter, for: id)
            } onCancel: {
                waiter.cancel()
            }

            // Check if shutdown happened while waiting
            if !isAcceptingWork {
                throw .shutdownInProgress
            }

            guard let enqueued else {
                // Entry was removed while waiting (not due to shutdown)
                throw .failure(.handle(.invalidID))
            }

            if !enqueued {
                throw .failure(.handle(.waitersFull))
            }

            // Capture cancellation state now, but still reclaim any reserved handle before throwing.
            // Cancellation is best-effort; we must not leak a reserved handle if cancellation wins the race.
            let wasCancelled = waiter.wasCancelled || Task.isCancelled

            // Re-validate after waiting - check shutdown first for correct error
            if !isAcceptingWork {
                throw .shutdownInProgress
            }
            guard let entry = handles[id], entry.state != .destroyed else {
                throw .failure(.handle(.invalidID))
            }

            // Claim handle - either reserved for us or present
            if case .reserved(let reservedToken) = entry.state, reservedToken == token {
                // Reservation path - claim by token (no contention possible)
                guard let h = entry.takeReserved(token: token) else {
                    throw .failure(.handle(.invalidID))
                }
                if wasCancelled {
                    // Reclaim handle before throwing - don't strand it in reserved state
                    _checkInHandle(consume h, for: id, entry: entry)
                    throw .cancelled
                }
                entry.state = .checkedOut
                checkedOutHandle = h
            } else if entry.state == .present, let h = entry.take() {
                // Fallback for edge cases (shouldn't normally happen with reservation)
                if wasCancelled {
                    // Reclaim handle before throwing
                    _checkInHandle(consume h, for: id, entry: entry)
                    throw .cancelled
                }
                entry.state = .checkedOut
                checkedOutHandle = h
            } else {
                // Handle not available for this waiter
                // If cancelled, report cancellation (not invalidID)
                if wasCancelled {
                    throw .cancelled
                }
                throw .failure(.handle(.invalidID))
            }
        }

        // Step 4: Execute body on lane using slot pattern
        var slot = IO.Executor.Slot.Container<Resource>.allocate()
        slot.initialize(with: checkedOutHandle)
        let address = slot.address

        let operationResult: Result<T, E>
        do {
            operationResult = try await lane.run(deadline: nil) { () throws(E) -> T in
                try IO.Executor.Slot.Container<Resource>.withResource(at: address) {
                    (resource: inout Resource) throws(E) -> T in
                    try body(&resource)
                }
            }
        } catch {
            // Map lane failures to lifecycle or operational errors
            _checkInHandle(slot.take(), for: id, entry: entry)
            slot.deallocateRawOnly()
            throw IO.Lifecycle.Error(error)
        }

        // Check if task was cancelled during execution
        let wasCancelled = Task.isCancelled

        // Move handle back out of slot and deallocate
        let checkedInHandle = slot.take()
        slot.deallocateRawOnly()

        // Step 5: Check-in handle
        _checkInHandle(checkedInHandle, for: id, entry: entry)

        // Handle cancellation
        if wasCancelled {
            throw .cancelled
        }

        // Return result or throw body error
        switch operationResult {
        case .success(let value):
            return value
        case .failure(let bodyError):
            throw .failure(.body(bodyError))
        }
    }
}

// MARK: - Handle Check-In

extension IO.Executor.Pool where Resource: ~Copyable {
    /// Check-in a handle after transaction.
    ///
    /// Uses reservation-based handoff when waiters exist:
    /// 1. Dequeue next armed waiter
    /// 2. Store handle in `reservedHandle` with waiter's token
    /// 3. Resume waiter - they claim by token (no re-validation needed)
    private func _checkInHandle(
        _ handle: consuming Resource,
        for id: IO.Handle.ID,
        entry: IO.Executor.Handle.Entry<Resource>
    ) {
        #if DEBUG
            entry._debugBeginMutation()
            defer { entry._debugEndMutation() }
        #endif

        if entry.state == .destroyed {
            // Entry marked for destruction - remove from registry
            handles.removeValue(forKey: id)
            _ = consume handle
            return
        }

        // Single-funnel draining:
        // Drain the queue completely - resume cancelled waiters, reserve for first eligible.
        // Only set .present when queue is truly empty.

        var h = consume handle

        while let waiter = entry.waiters.dequeue() {
            // Invariant: enqueued implies armed.
            // If this fires, actor isolation is broken.
            precondition(waiter.isArmed, "Waiter \(waiter.token) enqueued but not armed")

            // Already drained (shouldn't happen, but be defensive).
            if waiter.isDrained {
                continue
            }

            // Cancelled: resume immediately so task can observe cancellation.
            if waiter.wasCancelled {
                if let result = waiter.takeForResume() {
                    result.continuation.resume()
                }
                // Whether or not takeForResume succeeded, waiter is done.
                continue
            }

            // Non-cancelled, armed waiter: reserve and handoff.
            entry.reservedHandle = consume h
            entry.state = .reserved(waiterToken: waiter.token)

            guard let result = waiter.takeForResume() else {
                // Waiter got cancelled between our check and takeForResume.
                // Reclaim handle and continue draining.
                guard let reclaimed = entry.takeReserved(token: waiter.token) else {
                    // Reservation was already claimed somehow - invariant violation.
                    // Set present and bail (handle is lost but we avoid crash).
                    entry.state = .present
                    precondition(entry.waiters.isEmpty, "Setting present with waiters remaining")
                    return
                }
                h = consume reclaimed
                continue
            }

            result.continuation.resume()
            return
        }

        // Queue is empty, make handle present.
        entry.handle = consume h
        entry.state = .present
    }
}

// MARK: - Convenience API

extension IO.Executor.Pool where Resource: ~Copyable {
    /// Execute a closure with exclusive access to a handle.
    ///
    /// This is a convenience wrapper over `transaction(_:_:)`.
    public func withHandle<T: Sendable, E: Swift.Error & Sendable>(
        _ id: IO.Handle.ID,
        _ body: @Sendable @escaping (inout Resource) throws(E) -> T
    ) async throws(IO.Lifecycle.Error<IO.Error<E>>) -> T {
        do {
            return try await transaction(id, body)
        } catch {
            // Map transaction errors to IO.Error
            switch error {
            case .shutdownInProgress:
                throw .shutdownInProgress
            case .cancelled:
                throw .cancelled
            case .failure(let transactionError):
                switch transactionError {
                case .lane(let laneError):
                    throw .failure(.lane(laneError))
                case .handle(let handleError):
                    throw .failure(.handle(handleError))
                case .body(let bodyError):
                    throw .failure(.leaf(bodyError))
                }
            }
        }
    }
}

// MARK: - Handle Destruction

extension IO.Executor.Pool where Resource: ~Copyable {
    /// Mark a handle for destruction.
    ///
    /// If the handle is currently checked out, it will be destroyed
    /// when the transaction completes.
    ///
    /// - Parameter id: The handle ID.
    /// - Note: Idempotent for handles that were already destroyed.
    public func destroy(_ id: IO.Handle.ID) throws(IO.Handle.Error) {
        guard id.scope == scope else {
            throw .scopeMismatch
        }

        guard let entry = handles[id] else {
            // Already destroyed - idempotent
            return
        }

        if entry.state == .destroyed {
            // Already marked for destruction
            return
        }

        // If handle is checked out or reserved, mark for destruction on check-in
        switch entry.state {
        case .checkedOut, .reserved:
            entry.state = .destroyed
            // Drain waiters so they wake and see destroyed state
            entry.waiters.resumeAll()
            return
        case .present:
            // Handle is present - mark destroyed and remove
            entry.state = .destroyed
            entry.waiters.resumeAll()
            handles.removeValue(forKey: id)
        case .pendingRegistration:
            // Still being created - just remove the placeholder
            handles.removeValue(forKey: id)
        case .destroyed:
            // Already handled above
            break
        }
    }
}

// MARK: - Metrics

extension IO.Executor.Pool where Resource: ~Copyable {
    /// Observable metrics for the pool.
    ///
    /// Provides diagnostic information without exposing internal state.
    public struct Metrics: Sendable {
        /// Number of currently registered resources.
        public var registeredCount: Int

        /// Current lifecycle state of the pool.
        public var lifecycleState: IO.Lifecycle

        public init(registeredCount: Int, lifecycleState: IO.Lifecycle) {
            self.registeredCount = registeredCount
            self.lifecycleState = lifecycleState
        }
    }

    /// Current metrics for the pool.
    public var metrics: Metrics {
        Metrics(
            registeredCount: handles.count,
            lifecycleState: _lifecycle.load(ordering: .acquiring)
        )
    }
}
