//
//  IO.Completion.Queue.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 31/12/2025.
//

import Buffer
public import Kernel

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
        var pollThreadHandle: Kernel.Thread.Handle?

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
            } catch {
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
            } catch {
                throw .failure(error)
            }

            // Create wakeup channel
            let wakeupChannel: Wakeup.Channel
            do {
                wakeupChannel = try driver.createWakeupChannel(handle)
            } catch {
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

            // Spawn poll thread using Kernel.Handoff.Cell for ownership transfer
            let cell = Kernel.Handoff.Cell(context)
            let token = cell.token()

            do {
                self.pollThreadHandle = try Kernel.Thread.spawn {
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
            return IO.Completion.ID(id)
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

            // Void continuation - purely a wakeup latch, not a data path
            await withTaskCancellationHandler {
                await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                    let armed = waiter.arm(continuation: c)

                    if !armed {
                        // Cancelled before arm - task was cancelled between Waiter creation
                        // and arm(). Skip driver submission. Resume via Task {} hop to avoid
                        // reentrancy hazards (resuming before handler fully installed).
                        Task { waiter.resume.now() }
                        return
                    }

                    // Submit to poll thread via submission queue
                    submissions.push(storage)
                    wakeup.wake()

                    // Early completion: If completion arrived before we armed,
                    // drain() couldn't resume us (waiter wasn't armed).
                    // Now that we're armed, resume via Task {} hop for timing safety.
                    if storage.completion != nil {
                        Task { waiter.resume.now() }
                    }
                }
            } onCancel: {
                waiter.cancel()
                // Resume immediately - outside continuation closure, safe to call directly.
                // resume.now() is idempotent; if drain() already resumed, this is a no-op.
                waiter.resume.now()
            }

            // Actor decides outcome after await - single removal point
            guard let entry = entries.removeValue(forKey: id) else {
                throw .failure(.operation(.invalidSubmission))
            }

            // Extract buffer first (Pattern A preservation)
            var extractedBuffer: Buffer.Aligned? = nil
            swap(&extractedBuffer, &entry.storage.buffer)

            // === Outcome Decision: Completion-Wins Ordering ===
            //
            // Priority order (timeless invariant):
            //   1. Completion wins over everything (including cancellation AND shutdown)
            //   2. Cancellation wins only when no completion exists
            //   3. Shutdown only affects operations with no completion and no cancellation
            //
            // Rationale:
            // - Completed work should never be discarded
            // - Returning valid data is more useful to callers
            // - "Don't discard completed work" is a stable, decades-long rule
            //
            // Buffer is always returned (Pattern A preservation) regardless of outcome.

            let event: IO.Completion.Event
            if let completedEvent = entry.storage.completion {
                // COMPLETION WINS - deliver even if cancelled or shutdown
                entry.storage.completion = nil
                event = completedEvent
            } else if entry.waiter.wasCancelled {
                // Pattern A: Cancellation returns result with buffer, not throws.
                event = IO.Completion.Event(
                    id: id,
                    kind: entry.storage.kind,
                    outcome: IO.Completion.Outcome.cancellation
                )
            } else if isShutdown {
                // Shutdown only throws when no completion and no cancellation
                throw .failure(.lifecycle(.shutdownInProgress))
            } else {
                // Should not happen if invariants hold
                throw .failure(.operation(.invalidSubmission))
            }

            return IO.Completion.Submit.Result(event: event, buffer: extractedBuffer)
        }

        /// Cancels a pending operation (Phase 1 stub).
        ///
        /// In Phase 1, this is a no-op. Task cancellation is handled locally
        /// via `onCancel` handler; backend cancellation (CancelIoEx, io_uring
        /// IORING_OP_ASYNC_CANCEL) arrives in Phase 2.
        ///
        /// - Parameter id: The ID of the operation to cancel.
        public func cancel(id: IO.Completion.ID) throws(Failure) {
            guard !isShutdown else {
                throw .failure(.lifecycle(.shutdownInProgress))
            }

            // Phase 2: Submit cancel operation to backend
            // - IOCP: CancelIoEx
            // - io_uring: IORING_OP_ASYNC_CANCEL
        }

        // MARK: - Test Probes

        /// Result of waiting for a completion to be recorded.
        enum _RecordedResult {
            /// Completion was recorded in storage.
            case recorded
            /// Entry was finalized (removed) before completion was recorded.
            case finalizedWithoutRecord
            /// Timeout expired.
            case timeout
        }

        /// Counter of events processed by drain(). Test-only.
        var _drainedEventCount: UInt64 = 0

        /// Waits until a completion is recorded for the given ID.
        ///
        /// Test-only probe for synchronizing on "completion recorded" state.
        /// This is the correct barrier for completion-wins tests: wait until
        /// the actor has processed the bridge event, not just until the fake
        /// injected it.
        ///
        /// - Parameters:
        ///   - id: The operation ID to wait for.
        ///   - timeout: Maximum time to wait.
        /// - Returns: The outcome of the wait.
        func _waitUntilRecorded(
            _ id: IO.Completion.ID,
            timeout: Duration = .milliseconds(500)
        ) async -> _RecordedResult {
            let deadline = ContinuousClock.now + timeout
            while ContinuousClock.now < deadline {
                if let entry = entries[id] {
                    if entry.storage.completion != nil {
                        return .recorded
                    }
                } else {
                    return .finalizedWithoutRecord
                }
                await Task.yield()
            }
            return .timeout
        }

        /// Waits until drain has processed at least the given number of events.
        ///
        /// Test-only probe for proving late completions traverse the pipeline.
        func _waitUntilDrained(
            atLeast count: UInt64,
            timeout: Duration = .milliseconds(500)
        ) async -> Bool {
            let deadline = ContinuousClock.now + timeout
            while ContinuousClock.now < deadline {
                if _drainedEventCount >= count {
                    return true
                }
                await Task.yield()
            }
            return false
        }

        // MARK: - Event Processing

        /// Drains events from the bridge and resumes waiters.
        ///
        /// drain() does NOT remove entries - that happens in submit() after await.
        /// This ensures a single finalization point and proper early completion handling.
        /// The actor is the only place that decides the final outcome.
        ///
        /// Late completions for already-removed entries are safely ignored (not an error).
        func drain(_ events: [IO.Completion.Event]) {
            for event in events {
                _drainedEventCount += 1  // Test probe: track events processed

                // Look up entry but do NOT remove (submit() removes after await)
                guard let entry = entries[event.id] else {
                    // Late completion - entry already finalized by submit().
                    // This is expected under completion-wins + cancellation + shutdown.
                    // Simply drop it; not an invariant violation.
                    continue
                }

                // Store event in storage for submit() to consume
                entry.storage.completion = event

                // Resume waiter if armed. Uses resume.now() for proper state consumption.
                // If not armed yet, completion is stored in storage.
                // submit() will see it when it arms and resume immediately.
                entry.waiter.resume.now()
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
            // and throw lifecycle error. Use resume.now() for proper state consumption.
            for (_, entry) in entries {
                entry.waiter.resume.now()
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

            // Cancel drain task
            drainTask?.cancel()

            // Wait for poll thread to exit (must complete before closing wakeup)
            if let handle = pollThreadHandle._take() {
                handle.join()
            }

            // Close wakeup channel (after join to ensure poll thread exited cleanly)
            wakeupChannel.close()
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
