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
    /// The pool owns all entries in an actor-isolated registry.
    /// Handles are accessed via transactions that provide exclusive access.
    /// Only IDs cross await boundaries; entries never escape the actor.
    ///
    /// ## Generic over Resource
    /// The pool is generic over `Resource: ~Copyable`.
    /// This allows reuse for files, sockets, database connections, etc.
    /// Resources do NOT need to be Sendable because:
    /// - They are always actor-confined in the registry
    /// - Cross-boundary operations use the slot pattern (address is Sendable)
    /// - Teardown receives an address, not the resource directly
    public actor Pool<Resource: ~Copyable> {
        /// Teardown closure type for deterministic resource cleanup.
        ///
        /// When a resource is removed from the pool (via `destroy()`, `shutdown()`,
        /// or check-in after destruction), the pool calls this closure to perform
        /// resource-specific cleanup.
        ///
        /// The closure receives a `Slot.Address` (which is Sendable) rather than
        /// the resource directly. This allows teardown to run blocking operations
        /// on the lane without violating ~Copyable ownership rules.
        ///
        /// ## Example: File Handle Cleanup
        /// ```swift
        /// let pool = IO.Executor.Pool<File.Handle>(
        ///     lane: lane,
        ///     teardown: { address in
        ///         _ = try? await lane.run(deadline: nil) {
        ///             // MUST use consume(at:) or take(at:) to move resource out
        ///             IO.Executor.Slot.Container<File.Handle>.consume(at: address.pointer) {
        ///                 try? $0.close()
        ///             }
        ///         }
        ///     }
        /// )
        /// ```
        ///
        /// **Important**: The teardown closure MUST consume the resource at `address`
        /// using `consume(at:)` or `take(at:)`. Do NOT use `withResource(at:)` which
        /// only borrows. The pool deallocates the slot's raw memory after teardown
        /// returns - if the resource wasn't consumed, it will leak.
        public typealias TeardownClosure = @Sendable (_ address: IO.Executor.Slot.Address) async -> Void

        /// The lane for executing blocking operations.
        ///
        /// This is `nonisolated` because `Lane` is Sendable and immutable after init.
        public nonisolated let lane: IO.Blocking.Lane

        /// Unique scope identifier for this executor instance.
        public nonisolated let scope: UInt64

        /// Maximum waiters per handle.
        private let handleWaitersLimit: Int

        /// Resource teardown closure for deterministic cleanup.
        private let teardown: TeardownClosure

        /// Counter for generating unique handle IDs.
        private var nextRawID: UInt64 = 0

        /// Whether shutdown has been initiated.
        private var isShutdown: Bool = false

        /// Actor-owned handle registry.
        /// Each entry holds a Resource (or nil if checked out) plus waiters.
        private var entries: [IO.Handle.ID: IO.Executor.Handle.Entry<Resource>] = [:]

        // MARK: - Initializers

        /// Creates an executor with the given lane, backpressure policy, and teardown.
        ///
        /// Executors created with this initializer **must** be shut down
        /// when no longer needed using `shutdown()`.
        ///
        /// - Parameters:
        ///   - lane: The lane for executing blocking operations.
        ///   - policy: Backpressure policy (default: `.default`).
        ///   - teardown: Slot-based teardown closure. Default drops the resource.
        public init(
            lane: IO.Blocking.Lane,
            policy: IO.Backpressure.Policy = .default,
            teardown: @escaping TeardownClosure = { address in
                // Default: just consume/drop the resource
                _ = IO.Executor.Slot.Container<Resource>.take(at: address.pointer)
            }
        ) {
            self.lane = lane
            self.handleWaitersLimit = policy.handleWaitersLimit
            self.teardown = teardown
            self.scope = IO.Executor.scopeCounter.next()
        }

        /// Creates an executor with default Threads lane options.
        ///
        /// This is a convenience initializer equivalent to:
        /// ```swift
        /// Executor(lane: .threads(options), policy: options.policy, teardown: teardown)
        /// ```
        ///
        /// - Parameters:
        ///   - options: Options for the Threads lane.
        ///   - teardown: Slot-based teardown closure. Default drops the resource.
        public init(
            _ options: IO.Blocking.Threads.Options = .init(),
            teardown: @escaping TeardownClosure = { address in
                _ = IO.Executor.Slot.Container<Resource>.take(at: address.pointer)
            }
        ) {
            self.lane = .threads(options)
            self.handleWaitersLimit = options.policy.handleWaitersLimit
            self.teardown = teardown
            self.scope = IO.Executor.scopeCounter.next()
        }

        // MARK: - Execution

        /// Executes a blocking operation on the lane with typed throws.
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

        /// Shuts down the executor.
        ///
        /// 1. Marks executor as shut down (rejects new `run()` calls)
        /// 2. Resumes all waiters so they can exit gracefully
        /// 3. Tears down all remaining resources deterministically
        /// 4. Shuts down the lane
        public func shutdown() async {
            guard !isShutdown else { return }  // Idempotent
            isShutdown = true

            // Resume all waiters so they can observe shutdown
            for (_, entry) in entries {
                entry.waiters.resumeAll()
                entry.state = .destroyed
            }

            // Teardown each resource deterministically
            // Process one at a time since Resource is ~Copyable
            for (id, entry) in entries {
                if let resource = entry.take() {
                    entries.removeValue(forKey: id)
                    await _teardownResource(resource)
                } else {
                    entries.removeValue(forKey: id)
                }
            }

            // Shutdown the lane
            await lane.shutdown()
        }

        // MARK: - Handle Management

        /// Generates a unique handle ID.
        private func generateHandleID() -> IO.Handle.ID {
            let raw = nextRawID
            nextRawID += 1
            return IO.Handle.ID(raw: raw, scope: scope)
        }

        /// Registers a resource and returns its ID.
        ///
        /// This is the internal registration method. For non-Sendable resources,
        /// use `register(_:)` with a factory closure instead.
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
            entries[id] = IO.Executor.Handle.Entry(
                resource: resource,
                waitersCapacity: handleWaitersLimit
            )
            return id
        }

        /// Creates and registers a resource using a factory closure.
        ///
        /// This is the preferred registration method for non-Sendable resources.
        /// The factory runs on the lane (blocking I/O) and the resulting resource
        /// is registered atomically without crossing actor boundaries.
        ///
        /// Uses the slot pattern internally to transport the ~Copyable resource
        /// across the await boundary.
        ///
        /// ## Example: Opening and Registering a File
        /// ```swift
        /// let id = try await pool.register {
        ///     try File.Handle.open(path, mode: .read)
        /// }
        /// ```
        ///
        /// - Parameter make: Factory closure that creates the resource (runs on lane).
        /// - Returns: A unique handle ID for future operations.
        /// - Throws: `IO.Error<E>` on factory error or registration failure.
        public func register<E: Swift.Error & Sendable>(
            _ make: @Sendable @escaping () throws(E) -> Resource
        ) async throws(IO.Error<E>) -> IO.Handle.ID {
            guard !isShutdown else {
                throw .executor(.shutdownInProgress)
            }

            // Allocate slot for ~Copyable resource transport
            var slot = IO.Executor.Slot.Container<Resource>.allocate()
            let address = slot.address

            // Run factory on lane, storing result in slot
            let factoryResult: Result<Void, E>
            do {
                factoryResult = try await lane.run(deadline: nil) { () throws(E) -> Void in
                    let resource = try make()
                    IO.Executor.Slot.Container<Resource>.initializeMemory(at: address.pointer, with: resource)
                }
            } catch {
                slot.deallocateRawOnly()
                // error is IO.Blocking.Failure due to typed throws
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

            // Check factory result
            switch factoryResult {
            case .success:
                break
            case .failure(let factoryError):
                slot.deallocateRawOnly()
                throw .operation(factoryError)
            }

            // Take resource from slot and register
            slot.markInitialized()
            let resource = slot.take()
            slot.deallocateRawOnly()

            let id = generateHandleID()
            entries[id] = IO.Executor.Handle.Entry(
                resource: resource,
                waitersCapacity: handleWaitersLimit
            )
            return id
        }

        /// Checks if a handle ID is currently valid.
        ///
        /// - Parameter id: The handle ID to check.
        /// - Returns: `true` if the handle exists and is not destroyed.
        public func isValid(_ id: IO.Handle.ID) -> Bool {
            guard let entry = entries[id] else { return false }
            return entry.state != .destroyed
        }

        /// Checks if a handle ID refers to an open handle.
        ///
        /// This is the source of truth for handle liveness. Returns `true` if:
        /// - The ID belongs to this executor (scope match)
        /// - An entry exists in the registry
        /// - The entry is present or checked out (not destroyed)
        ///
        /// - Parameter id: The handle ID to check.
        /// - Returns: `true` if the handle is logically open.
        public func isOpen(_ id: IO.Handle.ID) -> Bool {
            guard id.scope == scope else { return false }
            guard let entry = entries[id] else { return false }
            return entry.isOpen
        }

        // MARK: - Transaction API

        /// Executes a transaction with exclusive handle access and typed errors.
        ///
        /// ## Semantics
        /// Transaction does not imply database-style atomicity or rollback:
        /// - Exclusive access to the resource (mutual exclusion)
        /// - Guaranteed check-in after body completes (including errors/cancellation)
        /// - No rollback or atomic commit semantics are implied
        // Algorithm:
        // 1. Validate scope and existence
        // 2. If resource available: move out (entry.resource = nil)
        // 3. Else: enqueue waiter and suspend (cancellation-safe)
        // 4. Execute via slot: allocate slot, run on lane, move handle back
        // 5. Check-in: restore handle or close if destroyed
        // 6. Resume next non-cancelled waiter
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
            guard let entry = entries[id] else {
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
                } onCancel: {
                    Task { await self._cancelWaiter(token: token, for: id) }
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
                guard let entry = entries[id], entry.state != .destroyed else {
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
                await _checkInHandle(slot.take(), for: id, entry: entry)
                slot.deallocateRawOnly()
                throw .lane(error)
            }

            // Check if task was cancelled during execution
            let wasCancelled = Task.isCancelled

            // Move handle back out of slot and deallocate
            let checkedInHandle = slot.take()
            slot.deallocateRawOnly()

            // Step 5: Check-in handle
            await _checkInHandle(checkedInHandle, for: id, entry: entry)

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
        ) async {
            if entry.state == .destroyed {
                // Entry marked for destruction - remove from registry first
                entries.removeValue(forKey: id)
                await _teardownResource(handle)
            } else {
                // Sync path - store handle back and resume waiter
                entry.resource = consume handle
                entry.state = .present
                entry.waiters.resumeNext()
            }
        }

        /// Cancels a waiter (called from cancellation handler).
        private func _cancelWaiter(token: UInt64, for id: IO.Handle.ID) {
            guard let entry = entries[id] else { return }
            if let continuation = entry.waiters.cancel(token: token) {
                continuation.resume()
            }
        }

        /// Executes a closure with exclusive access to a handle.
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

        /// Destroys a handle, tearing down the resource deterministically.
        ///
        /// If the handle is currently checked out, it will be destroyed
        /// when the transaction completes (teardown runs at check-in).
        ///
        /// If the handle is present, teardown runs immediately.
        ///
        /// - Parameter id: The handle ID.
        /// - Note: Idempotent for entries that were already destroyed.
        public func destroy(_ id: IO.Handle.ID) async throws(IO.Handle.Error) {
            guard id.scope == scope else {
                throw .scopeMismatch
            }

            guard let entry = entries[id] else {
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

            // Handle is present - mark destroyed, remove, and teardown
            entry.state = .destroyed
            entry.waiters.resumeAll()

            if let resource = entry.take() {
                entries.removeValue(forKey: id)
                await _teardownResource(resource)
            } else {
                entries.removeValue(forKey: id)
            }
        }

        // MARK: - Private Helpers

        /// Teardown a resource via the slot pattern.
        ///
        /// This helper centralizes the slot allocation/deallocation logic
        /// to prevent drift and ensure consistent teardown across all paths.
        private func _teardownResource(_ resource: consuming Resource) async {
            var slot = IO.Executor.Slot.Container<Resource>.allocate()
            slot.initialize(with: resource)
            let address = slot.address
            await teardown(address)
            slot.deallocateRawOnly()
        }
    }
}
