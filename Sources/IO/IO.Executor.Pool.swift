//
//  IO.Executor.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 24/12/2025.
//

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
    /// - **Full isolation**: All async methods are actor-isolated. No `nonisolated async`
    ///   surfaces that could hop to the global executor.
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

        /// Maximum waiters per handle (from backpressure policy).
        private let handleWaitersLimit: Int

        /// Counter for generating unique handle IDs.
        private var nextRawID: UInt64 = 0

        /// Whether shutdown has been initiated.
        private var isShutdown: Bool = false

        // MARK: - Submission Gate

        /// Single submission boundary gate.
        ///
        /// INVARIANT: All public methods that accept work (`run`, `register`, `transaction`)
        /// MUST check this at their start and reject immediately if false.
        ///
        /// This ensures:
        /// - Consistent rejection behavior across all entry points
        /// - Fail-fast before any expensive validation or state changes
        /// - Single point for future extensions (rate limiting, capacity checks)
        private var isAcceptingWork: Bool { !isShutdown }

        /// Actor-owned handle registry.
        /// Each entry holds a Resource (or nil if checked out) plus waiters.
        private var handles: [IO.Handle.ID: IO.Executor.Handle.Entry<Resource>] = [:]

        // MARK: - Custom Executor

        /// Returns the executor this actor runs on.
        ///
        /// This pins the actor to a specific executor thread from the shared pool,
        /// ensuring predictable scheduling behavior.
        public nonisolated var unownedExecutor: UnownedSerialExecutor {
            _executor.asUnownedSerialExecutor()
        }

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

        // MARK: - Initializers

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
        ///   - shardIndex: Shard index for use in `Shards` (default: 0).
        public init(
            lane: IO.Blocking.Lane,
            policy: IO.Backpressure.Policy = .default,
            shardIndex: UInt16 = 0
        ) {
            self._executor = IO.Executor.shared.next()
            self.lane = lane
            self.handleWaitersLimit = policy.handleWaitersLimit
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
        ///   - executor: The executor thread to run on.
        ///   - shardIndex: Shard index for use in `Shards` (default: 0).
        public init(
            lane: IO.Blocking.Lane,
            policy: IO.Backpressure.Policy = .default,
            executor: IO.Executor.Thread,
            shardIndex: UInt16 = 0
        ) {
            self._executor = executor
            self.lane = lane
            self.handleWaitersLimit = policy.handleWaitersLimit
            self.scope = IO.Executor.scopeCounter.next()
            self.shardIndex = shardIndex
        }

        /// Creates an executor with default Threads lane options.
        ///
        /// Uses round-robin assignment to select an executor from the shared pool.
        ///
        /// This is a convenience initializer equivalent to:
        /// ```swift
        /// Executor(lane: .threads(options), policy: options.policy)
        /// ```
        ///
        /// - Parameter options: Options for the Threads lane.
        public init(_ options: IO.Blocking.Threads.Options = .init()) {
            self._executor = IO.Executor.shared.next()
            self.lane = .threads(options)
            self.handleWaitersLimit = options.policy.handleWaitersLimit
            self.scope = IO.Executor.scopeCounter.next()
            self.shardIndex = 0
        }

        // MARK: - Execution

        /// Execute a blocking operation on the lane with typed throws.
        ///
        /// This method preserves the operation's specific error type while also
        /// capturing I/O infrastructure errors in `IO.Lifecycle.Error<IO.Error<E>>`.
        ///
        /// ## Cancellation Semantics
        /// - Cancellation before acceptance → `.cancelled`
        /// - Cancellation after acceptance → operation completes, then `.cancelled`
        ///
        /// - Parameter operation: The blocking operation to execute.
        /// - Returns: The result of the operation.
        /// - Throws: `IO.Lifecycle.Error<IO.Error<E>>` with lifecycle or operation errors.
        public func run<T: Sendable, E: Swift.Error & Sendable>(
            _ operation: @Sendable @escaping () throws(E) -> T
        ) async throws(IO.Lifecycle.Error<IO.Error<E>>) -> T {
            guard isAcceptingWork else {
                throw .shutdownInProgress
            }

            // Fast-path: if already cancelled, skip lane submission entirely
            if Task.isCancelled {
                throw .cancelled
            }

            // Lane.run throws(Failure) and returns Result<T, E>
            let result: Result<T, E>
            do {
                result = try await lane.run(deadline: nil, operation)
            } catch {
                // Map lane failures to lifecycle or operational errors
                switch error {
                case .shutdown:
                    throw .shutdownInProgress
                case .cancellationRequested:
                    throw .cancelled
                case .queueFull:
                    throw .failure(.lane(.queueFull))
                case .deadlineExceeded:
                    throw .failure(.lane(.deadlineExceeded))
                case .overloaded:
                    throw .failure(.lane(.overloaded))
                case .internalInvariantViolation:
                    throw .failure(.lane(.internalInvariantViolation))
                }
            }
            switch result {
            case .success(let value):
                return value
            case .failure(let error):
                throw .failure(.leaf(error))
            }
        }

        // MARK: - Shutdown

        /// Shut down the executor.
        ///
        /// 1. Marks executor as shut down (rejects new `run()` calls)
        /// 2. Resumes all waiters so they can exit gracefully
        /// 3. Shuts down the lane
        ///
        /// Note: Handle cleanup should be done by the caller before shutdown,
        /// or by providing a cleanup closure.
        public func shutdown() async {
            guard !isShutdown else { return }  // Idempotent
            isShutdown = true

            // Resume all waiters so they can observe shutdown
            for (_, entry) in handles {
                entry.waiters.resumeAll()
                entry.state = .destroyed
            }

            handles.removeAll()

            // Shutdown the lane
            await lane.shutdown()
        }

        // MARK: - Handle Management

        /// Generate a unique handle ID.
        private func generateHandleID() -> IO.Handle.ID {
            let raw = nextRawID
            nextRawID += 1
            return IO.Handle.ID(raw: raw, scope: scope, shard: shardIndex)
        }

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

        // MARK: - Transaction API

        /// Execute a transaction with exclusive handle access and typed errors.
        ///
        /// ## Semantics
        /// Transaction does not imply database-style atomicity or rollback:
        /// - Exclusive access to the resource (mutual exclusion)
        /// - Guaranteed check-in after body completes (including errors/cancellation)
        /// - No rollback or atomic commit semantics are implied
        ///
        /// ## Algorithm
        /// 1. Validate scope and existence
        /// 2. If handle available: move out (entry.handle = nil)
        /// 3. Else: enqueue waiter and suspend (cancellation-safe)
        /// 4. Execute via slot: allocate slot, run on lane, move handle back
        /// 5. Check-in: restore handle or close if destroyed
        /// 6. Resume next non-cancelled waiter
        ///
        /// ## Cancellation Semantics (Synchronous State Flip, Actor Drains on Next Touch)
        ///
        /// - `onCancel` handler only flips a cancelled bit synchronously (no Task, no resume)
        /// - The actor drains cancelled waiters during `resumeNext()` (on handle check-in)
        /// - Cancelled waiters wake, observe `wasCancelled`, and throw `.cancelled`
        /// - Cancellation after checkout: lane operation completes (if guaranteed),
        ///   handle is checked in, then `.cancelled` is thrown
        ///
        /// INVARIANT: All continuation resumption happens on the actor executor.
        /// No continuations are resumed from `onCancel` or while holding locks.
        public func transaction<T: Sendable, E: Swift.Error & Sendable>(
            _ id: IO.Handle.ID,
            _ body: @Sendable @escaping (inout Resource) throws(E) -> T
        ) async throws(IO.Lifecycle.Error<Transaction.Error<E>>) -> T {
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
                var enqueueFailed = false
                let waiter = IO.Handle.Waiter(token: token)

                await withTaskCancellationHandler {
                    await withCheckedContinuation {
                        (continuation: CheckedContinuation<Void, Never>) in
                        waiter.arm(continuation: continuation)
                        if !entry.waiters.enqueue(waiter) {
                            // Queue filled between check and enqueue (rare race)
                            enqueueFailed = true
                            // Drain immediately - we're on actor, this is safe
                            if let result = waiter.takeForResume() {
                                result.continuation.resume()
                            }
                        }
                    }
                } onCancel: {
                    // Synchronous state flip - NO Task, NO continuation resume.
                    // Actor drains cancelled waiters on next touch (resumeNext).
                    waiter.cancel()
                }

                // Handle enqueue failure
                if enqueueFailed {
                    throw .failure(.handle(.waitersFull))
                }

                // Check if we were cancelled (waiter knows, or use Task.isCancelled)
                if waiter.wasCancelled {
                    throw .cancelled
                }

                // Re-validate after waiting
                guard let entry = handles[id], entry.state != .destroyed else {
                    throw .failure(.handle(.invalidID))
                }

                // Claim handle - either reserved for us or present
                if case .reserved(let reservedToken) = entry.state, reservedToken == token {
                    // Reservation path - claim by token (no contention possible)
                    guard let h = entry.takeReserved(token: token) else {
                        throw .failure(.handle(.invalidID))
                    }
                    entry.state = .checkedOut
                    checkedOutHandle = h
                } else if entry.state == .present, let h = entry.take() {
                    // Fallback for edge cases (shouldn't normally happen with reservation)
                    entry.state = .checkedOut
                    checkedOutHandle = h
                } else {
                    // Handle not available - unexpected state
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
                switch error {
                case .shutdown:
                    throw .shutdownInProgress
                case .cancellationRequested:
                    throw .cancelled
                case .queueFull:
                    throw .failure(.lane(.queueFull))
                case .deadlineExceeded:
                    throw .failure(.lane(.deadlineExceeded))
                case .overloaded:
                    throw .failure(.lane(.overloaded))
                case .internalInvariantViolation:
                    throw .failure(.lane(.internalInvariantViolation))
                }
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
            if entry.state == .destroyed {
                // Entry marked for destruction - remove from registry
                // The resource is dropped here (caller should handle cleanup)
                handles.removeValue(forKey: id)
                _ = consume handle
            } else if let waiter = entry.waiters.dequeueNextArmed() {
                // Reservation path - assign handle to specific waiter
                entry.reservedHandle = consume handle
                entry.state = .reserved(waiterToken: waiter.token)
                // Resume waiter - they will claim by token
                if let result = waiter.takeForResume() {
                    result.continuation.resume()
                }
            } else {
                // No waiters - make handle present
                entry.handle = consume handle
                entry.state = .present
            }
        }

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
            case .destroyed:
                // Already handled above
                break
            }
        }
    }
}
