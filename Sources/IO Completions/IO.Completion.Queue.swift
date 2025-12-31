//
//  IO.Completion.Queue.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 31/12/2025.
//

public import Buffer

extension IO.Completion {
    /// The completion queue manages async I/O operations.
    ///
    /// The Queue is the primary interface for submitting completion-based
    /// I/O operations. It manages:
    /// - Operation submission to the driver
    /// - Waiter registration for async completion
    /// - Event dispatch from the poll thread
    /// - Graceful shutdown
    ///
    /// ## Architecture
    ///
    /// ```
    /// ┌─────────────┐     submit      ┌─────────────┐
    /// │   Client    │ ──────────────► │    Queue    │
    /// │   (async)   │                 │   (actor)   │
    /// └─────────────┘                 └──────┬──────┘
    ///                                        │
    ///                          ┌─────────────┴─────────────┐
    ///                          │    Submission.Queue       │
    ///                          │  (thread-safe MPSC ring)  │
    ///                          └─────────────┬─────────────┘
    ///                                        │
    ///                                        ▼
    ///                               ┌─────────────────┐
    ///                               │   Poll Thread   │
    ///                               │  (Driver.poll)  │
    ///                               └────────┬────────┘
    ///                                        │
    ///                          ┌─────────────┴─────────────┐
    ///                          │         Bridge            │
    ///                          │  (poll thread → actor)    │
    ///                          └─────────────┬─────────────┘
    ///                                        │
    ///                                        ▼
    ///                               ┌─────────────────┐
    ///                               │  Queue.drain()  │
    ///                               │ (resume waiters)│
    ///                               └─────────────────┘
    /// ```
    ///
    /// ## Thread Safety
    ///
    /// Queue is an actor. All state mutations happen on the actor executor.
    /// The poll thread never resumes continuations directly - it pushes
    /// events to the Bridge, and the actor drains them.
    ///
    /// ## Typed Errors
    ///
    /// Uses `throws(Failure)` with non-throwing continuations and typed
    /// `Submit.Outcome` to maintain full type safety without existential errors.
    ///
    /// ## Cancellation Invariant
    ///
    /// The actor is the only place that decides the final outcome.
    /// Poll thread delivers events; actor maps {event, waiter.state, storage.state}
    /// → Submit.Outcome. This preserves the Bridge invariant.
    ///
    /// ## Usage
    ///
    /// ```swift
    /// let queue = try await IO.Completion.Queue()
    ///
    /// // Submit a read operation
    /// var buffer = try Buffer.Aligned(byteCount: 4096, alignment: 4096)
    /// var take = try await queue.submit(
    ///     .read(from: fd, into: buffer, id: queue.nextID())
    /// ).take()
    /// let event = take.event
    /// if var buffer = take.buffer() {
    ///     // Use the buffer
    /// }
    /// ```
    public actor Queue {
        /// The driver backend.
        let driver: Driver

        /// The poll thread.
        let pollThread: IO.Executor.Thread

        /// The wakeup channel for signaling the poll thread.
        let wakeupChannel: Wakeup.Channel

        /// The bridge for poll thread → actor event handoff.
        let bridge: Bridge

        /// Unified entry tracking.
        ///
        /// Each entry contains both the waiter and operation storage,
        /// ensuring they are always removed together and preventing
        /// "buffer not recovered" bugs.
        private var entries: [IO.Completion.ID: Entry] = [:]

        /// Next operation ID.
        private var _nextID: UInt64 = 1

        /// Whether shutdown has been initiated.
        private var isShutdown: Bool = false

        // MARK: - Entry

        /// Unified tracking entry containing waiter and operation storage.
        ///
        /// `@unchecked Sendable` because both `Waiter` and `Operation.Storage`
        /// provide internal synchronization.
        private struct Entry: @unchecked Sendable {
            let waiter: Waiter
            let storage: Operation.Storage
        }

        // MARK: - Initialization

        /// Creates a completion queue with the best available driver.
        ///
        /// - Throws: If driver creation fails.
        public init() async throws(Failure) {
            let driver: Driver
            do {
                driver = try Driver.bestAvailable()
            } catch {
                throw .failure(error)
            }
            try await self.init(driver: driver)
        }

        /// Creates a completion queue with a specific driver.
        ///
        /// - Parameter driver: The driver to use.
        /// - Throws: If handle or poll thread creation fails.
        public init(driver: Driver) async throws(Failure) {
            self.driver = driver
            self.bridge = Bridge()

            let handle: Driver.Handle
            do {
                handle = try driver.create()
            } catch {
                throw .failure(error)
            }

            let wakeupChannel: Wakeup.Channel
            do {
                wakeupChannel = try driver.createWakeupChannel(handle)
            } catch {
                throw .failure(error)
            }
            self.wakeupChannel = wakeupChannel

            // Start poll thread
            // Note: In a real implementation, this would properly transfer
            // the handle to the poll thread
            let pollThread: IO.Executor.Thread
            do {
                pollThread = try IO.Executor.Thread(name: "io-completion-poll") {
                    // Poll loop would run here
                }
            } catch {
                throw .failure(.lifecycle(.resourceExhausted))
            }
            self.pollThread = pollThread
        }

        deinit {
            // Cleanup
            wakeupChannel.close()
        }

        // MARK: - ID Generation

        /// Gets the next operation ID.
        public func nextID() -> IO.Completion.ID {
            let id = _nextID
            _nextID += 1
            return IO.Completion.ID(raw: id)
        }

        // MARK: - Submission

        /// Submits an operation and awaits its completion.
        ///
        /// Uses non-throwing continuation with typed `Submit.Outcome` to
        /// maintain typed error discipline. The switch at the end converts
        /// the outcome to a typed throw.
        ///
        /// - Parameter operation: The operation to submit.
        /// - Returns: The submission result containing event and buffer.
        /// - Throws: On submission failure, cancellation, or operation error.
        public func submit(
            _ operation: consuming Operation
        ) async throws(Failure) -> IO.Completion.Submit.Result {
            guard !isShutdown else {
                throw .failure(.lifecycle(.shutdownInProgress))
            }

            let storage = operation.storage
            let id = storage.id

            // Create waiter and register unified entry
            let waiter = Waiter(id: id)
            entries[id] = Entry(waiter: waiter, storage: storage)

            // Capture wakeup for cancellation handler
            let wakeup = wakeupChannel

            // Non-throwing continuation with typed outcome
            let outcome: IO.Completion.Submit.Outcome = await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    let armed = waiter.arm(continuation: continuation)
                    precondition(armed, "Waiter must arm exactly once")

                    // Submit to driver would happen here
                    // driver.submit(handle, storage)
                }
            } onCancel: {
                waiter.cancel()
                wakeup.wake()
            }

            // Convert outcome to typed throw
            switch outcome {
            case .success(let result):
                return result
            case .failure(let failure):
                throw failure
            }
        }

        /// Cancels a pending operation.
        ///
        /// - Parameter id: The ID of the operation to cancel.
        public func cancel(id: IO.Completion.ID) throws(Failure) {
            guard !isShutdown else {
                throw .failure(.lifecycle(.shutdownInProgress))
            }

            // Submit cancel operation to backend
            // In a real implementation:
            // - IOCP: CancelIoEx
            // - io_uring: IORING_OP_ASYNC_CANCEL
        }

        // MARK: - Event Processing

        /// Drains events from the bridge and resumes waiters.
        ///
        /// The actor is the only place that decides the final outcome.
        /// This preserves the Bridge invariant and ensures exactly-once
        /// resumption semantics.
        func drain(_ events: [IO.Completion.Event]) {
            for event in events {
                guard let entry = entries.removeValue(forKey: event.id) else {
                    // Stale completion (already cancelled and drained)
                    continue
                }

                // Buffer is always from entry.storage
                let buffer = entry.storage.buffer
                entry.storage.buffer = nil  // Transfer ownership

                // Actor decides final outcome based on waiter state
                if let (continuation, wasCancelled) = entry.waiter.take.forResume() {
                    if wasCancelled {
                        continuation.resume(returning: .failure(.cancelled))
                    } else {
                        let result = IO.Completion.Submit.Result(event: event, buffer: buffer)
                        continuation.resume(returning: .success(result))
                    }
                }
            }
        }

        // MARK: - Shutdown

        /// Initiates graceful shutdown.
        ///
        /// All pending operations are cancelled and the poll thread is stopped.
        public func shutdown() async throws(Failure) {
            guard !isShutdown else { return }
            isShutdown = true

            // Cancel all pending operations
            for (id, _) in entries {
                try? cancel(id: id)
            }

            // Drain all waiters with shutdown error
            for (_, entry) in entries {
                if let (continuation, _) = entry.waiter.take.forResume() {
                    continuation.resume(returning: .failure(.failure(.lifecycle(.shutdownInProgress))))
                }
            }
            entries.removeAll()

            // Signal bridge shutdown
            bridge.shutdown()

            // Wake poll thread to exit
            wakeupChannel.wake()

            // Wait for poll thread to exit
            // pollThread.join() - would be called here
        }
    }
}

// MARK: - Best Available Driver

extension IO.Completion.Driver {
    /// Returns the best available driver for the current platform.
    ///
    /// - **Windows**: IOCP
    /// - **Linux**: io_uring if available, else EventsAdapter (epoll)
    /// - **Darwin**: EventsAdapter (kqueue)
    ///
    /// - Throws: If no driver can be created.
    public static func bestAvailable() throws(IO.Completion.Error) -> Driver {
        #if os(Windows)
        return IO.Completion.IOCP.driver()
        #elseif os(Linux)
        if IO.Completion.IOUring.isSupported {
            return try IO.Completion.IOUring.driver()
        } else {
            return IO.Completion.EventsAdapter.driver()
        }
        #else
        return IO.Completion.EventsAdapter.driver()
        #endif
    }
}
