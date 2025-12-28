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

        /// Maximum waiters per handle (from backpressure policy).
        private let handleWaitersLimit: Int

        /// Counter for generating unique handle IDs.
        private var nextRawID: UInt64 = 0

        /// Whether shutdown has been initiated.
        private var isShutdown: Bool = false

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
        public init(lane: IO.Blocking.Lane, policy: IO.Backpressure.Policy = .default) {
            self._executor = IO.Executor.shared.next()
            self.lane = lane
            self.handleWaitersLimit = policy.handleWaitersLimit
            self.scope = IO.Executor.scopeCounter.next()
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
        public init(
            lane: IO.Blocking.Lane,
            policy: IO.Backpressure.Policy = .default,
            executor: IO.Executor.Thread
        ) {
            self._executor = executor
            self.lane = lane
            self.handleWaitersLimit = policy.handleWaitersLimit
            self.scope = IO.Executor.scopeCounter.next()
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
        }

        // MARK: - Execution

        /// Execute a blocking operation on the lane with typed throws.
        ///
        /// This method preserves the operation's specific error type while also
        /// capturing I/O infrastructure errors in `IO.Error<E>`.
        ///
        /// ## Cancellation Semantics
        /// - Cancellation before acceptance → `.cancelled`
        /// - Cancellation after acceptance → operation completes, then `.cancelled`
        ///
        /// - Parameter operation: The blocking operation to execute.
        /// - Returns: The result of the operation.
        /// - Throws: `IO.Error<E>` with the specific operation error or infrastructure error.
        public func run<T: Sendable, E: Swift.Error & Sendable>(
            _ operation: @Sendable @escaping () throws(E) -> T
        ) async throws(IO.Error<E>) -> T {
            guard !isShutdown else {
                throw .executor(.shutdownInProgress)
            }

            // Lane.run throws(Failure) and returns Result<T, E>
            let result: Result<T, E>
            do {
                result = try await lane.run(deadline: nil, operation)
            } catch {
                // error is statically Failure due to typed throws
                switch error {
                case .shutdown:
                    throw .executor(.shutdownInProgress)
                case .queueFull:
                    throw .lane(.queueFull)
                case .deadlineExceeded:
                    throw .lane(.deadlineExceeded)
                case .cancelled:
                    throw .cancelled
                case .overloaded:
                    throw .lane(.overloaded)
                case .internalInvariantViolation:
                    throw .lane(.internalInvariantViolation)
                }
            }
            switch result {
            case .success(let value):
                return value
            case .failure(let error):
                throw .operation(error)
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
            return IO.Handle.ID(raw: raw, scope: scope)
        }

        /// Register a resource and return its ID.
        ///
        /// - Parameter resource: The resource to register (ownership transferred).
        /// - Returns: A unique handle ID for future operations.
        /// - Throws: `Executor.Error.shutdownInProgress` if executor is shut down.
        public func register(
            _ resource: consuming Resource
        ) throws(IO.Executor.Error) -> IO.Handle.ID {
            guard !isShutdown else {
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
        /// ## Cancellation Semantics
        /// - Cancellation while waiting: waiter marked cancelled, resumes, throws CancellationError
        /// - Cancellation after checkout: lane operation completes (if guaranteed),
        ///   handle is checked in, then CancellationError is thrown
        public func transaction<T: Sendable, E: Swift.Error & Sendable>(
            _ id: IO.Handle.ID,
            _ body: @Sendable @escaping (inout Resource) throws(E) -> T
        ) async throws(Transaction.Error<E>) -> T {
            // Step 1: Validate scope
            guard id.scope == scope else {
                throw .handle(.scopeMismatch)
            }

            // Step 2: Checkout handle (with waiting if needed)
            guard let entry = handles[id] else {
                throw .handle(.invalidID)
            }

            if entry.state == .destroyed {
                throw .handle(.invalidID)
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
                    throw .handle(.waitersFull)
                }

                let token = entry.waiters.generateToken()
                var enqueueFailed = false

                await withTaskCancellationHandler {
                    await withCheckedContinuation {
                        (continuation: CheckedContinuation<Void, Never>) in
                        if !entry.waiters.enqueue(token: token, continuation: continuation) {
                            // Queue filled between check and enqueue (rare race)
                            enqueueFailed = true
                            continuation.resume()  // Resume immediately
                        }
                    }
                } onCancel: { [executor = self._executor] in
                    Task(executorPreference: executor) {
                        await self._cancelWaiter(token: token, for: id)
                    }
                }

                // Handle enqueue failure
                if enqueueFailed {
                    throw .handle(.waitersFull)
                }

                // Check cancellation after waking
                do {
                    try Task.checkCancellation()
                } catch {
                    throw .lane(.cancelled)
                }

                // Re-validate after waiting
                guard let entry = handles[id], entry.state != .destroyed else {
                    throw .handle(.invalidID)
                }

                guard entry.state == .present, let h = entry.take() else {
                    throw .handle(.invalidID)
                }

                entry.state = .checkedOut
                checkedOutHandle = h
            }

            // Step 4: Execute body on lane using slot pattern
            var slot = IO.Executor.Slot.Container<Resource>.allocate()
            slot.initialize(with: checkedOutHandle)
            let address = slot.address

            let operationResult: Result<T, E>
            do {
                operationResult = try await lane.run(deadline: nil) { () throws(E) -> T in
                    let raw = address.pointer
                    return try IO.Executor.Slot.Container<Resource>.withResource(at: raw) {
                        (resource: inout Resource) throws(E) -> T in
                        try body(&resource)
                    }
                }
            } catch {
                // error is statically IO.Blocking.Failure due to typed throws
                _checkInHandle(slot.take(), for: id, entry: entry)
                slot.deallocateRawOnly()
                throw .lane(error)
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
                throw .lane(.cancelled)
            }

            // Return result or throw body error
            switch operationResult {
            case .success(let value):
                return value
            case .failure(let bodyError):
                throw .body(bodyError)
            }
        }

        /// Check-in a handle after transaction.
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
            } else {
                // Sync path - store handle back and resume waiter
                entry.handle = consume handle
                entry.state = .present
                entry.waiters.resumeNext()
            }
        }

        /// Cancel a waiter (called from cancellation handler).
        private func _cancelWaiter(token: UInt64, for id: IO.Handle.ID) {
            guard let entry = handles[id] else { return }
            if let continuation = entry.waiters.cancel(token: token) {
                continuation.resume()
            }
        }

        /// Execute a closure with exclusive access to a handle.
        ///
        /// This is a convenience wrapper over `transaction(_:_:)`.
        public func withHandle<T: Sendable, E: Swift.Error & Sendable>(
            _ id: IO.Handle.ID,
            _ body: @Sendable @escaping (inout Resource) throws(E) -> T
        ) async throws(IO.Error<E>) -> T {
            do {
                return try await transaction(id, body)
            } catch {
                switch error {
                case .lane(let error):
                    switch error {
                    case .shutdown:
                        throw .executor(.shutdownInProgress)
                    case .queueFull:
                        throw .lane(.queueFull)
                    case .deadlineExceeded:
                        throw .lane(.deadlineExceeded)
                    case .cancelled:
                        throw .cancelled
                    case .overloaded:
                        throw .lane(.overloaded)
                    case .internalInvariantViolation:
                        throw .lane(.internalInvariantViolation)
                    }
                case .handle(let handleError):
                    throw .handle(handleError)
                case .body(let bodyError):
                    throw .operation(bodyError)
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

            // If handle is checked out, mark for destruction on check-in
            if entry.state == .checkedOut {
                entry.state = .destroyed
                // Drain waiters so they wake and see destroyed state
                entry.waiters.resumeAll()
                return
            }

            // Handle is present - mark destroyed and remove
            entry.state = .destroyed
            entry.waiters.resumeAll()
            handles.removeValue(forKey: id)
        }
    }
}
