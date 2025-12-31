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
    /// Uses `throws(Failure)` with non-throwing continuations carrying Copyable IDs.
    /// Buffer and event are extracted from storage after await, maintaining full
    /// type safety without existential errors.
    ///
    /// ## Cancellation Invariant
    ///
    /// The actor is the only place that decides the final outcome.
    /// Poll thread delivers events; actor maps {event, waiter.state, storage.state}
    /// → Submit.Result. Cancellation returns buffer via Pattern A preservation.
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

        /// The submission queue for actor → poll thread handoff.
        let submissions: Submission.Queue

        /// The bridge for poll thread → actor event handoff.
        let bridge: Bridge

        /// The wakeup channel for signaling the poll thread.
        let wakeupChannel: Wakeup.Channel

        /// The shutdown flag for the poll loop.
        let shutdownFlag: PollLoop.Shutdown.Flag

        /// The poll thread handle.
        var pollThreadHandle: IO.Thread.Handle?

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

        /// The bridge drain task.
        private var drainTask: Task<Void, Never>?

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
            let driver: IO.Completion.Driver
            do {
                driver = try IO.Completion.Driver.bestAvailable()
            } catch let error as IO.Completion.Error {
                throw .failure(error)
            }
            try await self.init(driver: driver)
        }

        /// Creates a completion queue with a specific driver.
        ///
        /// - Parameter driver: The driver to use.
        /// - Throws: If handle or poll thread creation fails.
        public init(driver: IO.Completion.Driver) async throws(Failure) {
            self.driver = driver

            // Create thread-safe primitives
            self.submissions = Submission.Queue()
            self.bridge = Bridge()
            self.shutdownFlag = PollLoop.Shutdown.Flag()

            // Create driver handle
            let handle: IO.Completion.Driver.Handle
            do {
                handle = try driver.create()
            } catch let error as IO.Completion.Error {
                throw .failure(error)
            }

            // Create wakeup channel
            let wakeupChannel: Wakeup.Channel
            do {
                wakeupChannel = try driver.createWakeupChannel(handle)
            } catch let error as IO.Completion.Error {
                throw .failure(error)
            }
            self.wakeupChannel = wakeupChannel

            // Build poll loop context (consumes handle)
            let context = PollLoop.Context(
                driver: driver,
                handle: handle,
                submissions: submissions,
                wakeup: wakeupChannel,
                bridge: bridge,
                shutdownFlag: shutdownFlag
            )

            // Spawn poll thread using IO.Handoff.Cell for ownership transfer
            let cell = IO.Handoff.Cell(context)
            let token = cell.token()

            do {
                self.pollThreadHandle = try IO.Thread.spawn {
                    let ctx = token.take()
                    PollLoop.run(ctx)
                }
            } catch {
                // Poll thread creation failed - clean up
                wakeupChannel.close()
                throw .failure(.lifecycle(.queueClosed))
            }

            // Start bridge drain task
            self.drainTask = Task { [weak self] in
                while let events = await self?.bridge.next() {
                    await self?.drain(events)
                }
            }
        }

        deinit {
            // Cleanup - drain task and wakeup channel
            drainTask?.cancel()
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
        /// Uses typed throws for lifecycle errors only. Cancellation returns
        /// a result with `event.outcome == .cancelled` to preserve Pattern A:
        /// buffer is always returned to the caller.
        ///
        /// - Parameter operation: The operation to submit.
        /// - Returns: The submission result containing event and buffer.
        /// - Throws: On lifecycle errors or invalid submission.
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

            // Continuation carries only ID (Copyable)
            let _: IO.Completion.ID = await withTaskCancellationHandler {
                await withCheckedContinuation { (c: CheckedContinuation<IO.Completion.ID, Never>) in
                    let armed = waiter.arm(continuation: c)

                    if !armed {
                        // Cancelled before arm - task was cancelled between Waiter creation
                        // and arm(). Skip driver submission. Resume via Task {} hop to avoid
                        // reentrancy hazards (resume before handler installation).
                        Task { waiter.resume.id(id) }
                        return
                    }

                    // Submit to poll thread via submission queue
                    submissions.push(storage)
                    wakeup.wake()

                    // Early completion: If completion arrived before we armed,
                    // drain() couldn't resume us (waiter wasn't armed).
                    // Now that we're armed, resume via Task {} hop for safety.
                    if storage.completion != nil {
                        Task { waiter.resume.id(id) }
                    }
                }
            } onCancel: {
                waiter.cancel()
                wakeup.wake()
            }

            // Actor decides outcome after await - single removal point
            guard let entry = entries.removeValue(forKey: id) else {
                throw .failure(.operation(.invalidSubmission))
            }

            // Extract buffer first (Pattern A preservation)
            var extractedBuffer: Buffer.Aligned? = nil
            swap(&extractedBuffer, &entry.storage.buffer)

            // Check for shutdown (takes priority over cancellation)
            if isShutdown {
                throw .failure(.lifecycle(.shutdownInProgress))
            }

            // === Cancellation Semantics: Completion-Wins (v1) ===
            //
            // If a kernel completion is recorded for an operation, deliver it even if
            // the task was cancelled. Rationale:
            // - Completed work should not be discarded
            // - Returning valid data is more useful to callers
            // - Simpler implementation (no completion suppression across platforms)
            //
            // The waiter.wasCancelled flag is only consulted when no completion arrived.
            // Buffer is always returned (Pattern A preservation) regardless of outcome.
            // Cancellation is best-effort; late kernel completions may arrive and will
            // be drained/discarded safely if the submission has been logically concluded.

            // Determine event: either from completion or synthesized for cancellation
            let event: IO.Completion.Event
            if let completedEvent = entry.storage.completion {
                entry.storage.completion = nil
                event = completedEvent
            } else if entry.waiter.wasCancelled {
                // Pattern A: Cancellation returns result with buffer, not throws.
                // Channel layer can convert to throw if desired.
                event = IO.Completion.Event(
                    id: id,
                    kind: entry.storage.kind,
                    outcome: IO.Completion.Outcome.cancelled
                )
            } else {
                throw .failure(.operation(.invalidSubmission))
            }

            return IO.Completion.Submit.Result(event: event, buffer: extractedBuffer)
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
        /// drain() does NOT remove entries - that happens in submit() after await.
        /// This ensures a single finalization point and proper early completion handling.
        /// The actor is the only place that decides the final outcome.
        func drain(_ events: [IO.Completion.Event]) {
            for event in events {
                // Look up entry but do NOT remove (submit() removes after await)
                guard let entry = entries[event.id] else {
                    // Stale completion (already finalized by submit())
                    continue
                }

                // Store event in storage for submit() to consume
                entry.storage.completion = event

                // Resume waiter if armed. Uses resume.id() for proper state consumption.
                // If not armed yet, completion is stored in storage.
                // submit() will see it when it arms and resume immediately.
                entry.waiter.resume.id(event.id)
            }
        }

        // MARK: - Shutdown

        /// Initiates graceful shutdown.
        ///
        /// All pending operations are cancelled and the poll thread is stopped.
        /// Waiters will receive lifecycle(.shutdownInProgress) error after await.
        ///
        /// - Note: shutdown() should only be called when no new submits are in progress.
        ///   Unarmed waiters will progress when they arm (submit sees isShutdown).
        public func shutdown() async {
            guard !isShutdown else { return }
            isShutdown = true

            // Cancel all pending operations with the backend
            for (id, _) in entries {
                try? cancel(id: id)
            }

            // Resume all armed waiters - they will see isShutdown after await
            // and throw lifecycle error. Use resume.id() for proper state consumption.
            for (id, entry) in entries {
                entry.waiter.resume.id(id)
            }
            // Note: entries are not removed here - submit() will remove them
            // and throw lifecycle error when it sees isShutdown.
            // Unarmed waiters: when they arm in submit(), they will proceed
            // immediately (continuation resumes) and see isShutdown after await.

            // Set shutdown flag for poll loop
            shutdownFlag.set()

            // Signal bridge shutdown
            bridge.shutdown()

            // Wake poll thread to exit
            wakeupChannel.wake()

            // Close wakeup channel
            wakeupChannel.close()

            // Cancel drain task
            drainTask?.cancel()

            // Wait for poll thread to exit
            if let handle = pollThreadHandle._take() {
                handle.join()
            }
        }
    }
}

// MARK: - Best Available Driver

extension IO.Completion.Driver {
    /// Returns the best available driver for the current platform.
    ///
    /// - **Windows**: IOCP
    /// - **Linux**: io_uring (throws if unavailable)
    /// - **Darwin**: throws `.capability(.backendUnavailable)` - no completion backend
    ///
    /// Darwin has no true completion-based I/O facility. Use `IO.Events` (kqueue)
    /// for Darwin. This separation keeps IO.Completion semantically pure:
    /// only real proactor backends (IOCP, io_uring) are supported.
    ///
    /// - Throws: If no driver can be created or platform lacks completion support.
    public static func bestAvailable() throws(IO.Completion.Error) -> IO.Completion.Driver {
        #if os(Windows)
        return try IO.Completion.IOCP.driver()
        #elseif os(Linux)
        guard IO.Completion.IOUring.isSupported else {
            throw .capability(.backendUnavailable)
        }
        return try IO.Completion.IOUring.driver()
        #else
        throw .capability(.backendUnavailable)
        #endif
    }
}
