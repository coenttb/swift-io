//
//  IO.Completion.PollLoop.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 31/12/2025.
//

import Synchronization

extension IO.Completion {
    /// Namespace for poll loop types.
    public enum PollLoop {}
}

// MARK: - Shutdown Flag

extension IO.Completion.PollLoop {
    /// Namespace for shutdown-related types.
    public enum Shutdown {}
}

extension IO.Completion.PollLoop.Shutdown {
    /// Atomic flag for signaling poll loop shutdown.
    ///
    /// The flag is set by the queue actor and checked by the poll thread.
    /// Uses acquire/release ordering for proper synchronization.
    ///
    /// ## Thread Safety
    ///
    /// `@unchecked Sendable` because it provides internal synchronization via `Atomic`.
    public final class Flag: @unchecked Sendable {
        private let _isSet: Atomic<Bool>

        /// Creates an unset shutdown flag.
        public init() {
            self._isSet = Atomic(false)
        }

        /// Whether the shutdown flag is set.
        public var isSet: Bool {
            _isSet.load(ordering: .acquiring)
        }

        /// Sets the shutdown flag.
        ///
        /// After calling this, the poll loop will exit on its next iteration.
        public func set() {
            _isSet.store(true, ordering: .releasing)
        }
    }
}

// MARK: - Context

extension IO.Completion.PollLoop {
    /// Context for running the poll loop.
    ///
    /// Contains all resources needed by the poll thread. The `handle` is
    /// consumed by `run()`, ensuring proper ownership transfer.
    ///
    /// ## Ownership
    ///
    /// - `handle`: Owned by Context, consumed by `run()`
    /// - `driver`: Borrowed (Sendable, shared)
    /// - Other fields: Borrowed (Sendable, shared)
    ///
    /// ## Creation
    ///
    /// Created by the queue actor during initialization, then transferred
    /// to the poll thread via `IO.Handoff.Cell`.
    public struct Context: ~Copyable, @unchecked Sendable {
        /// The driver backend.
        public let driver: IO.Completion.Driver

        /// The completion handle. Consumed by `run()`.
        public var handle: IO.Completion.Driver.Handle

        /// The submission queue for actor → poll thread handoff.
        public let submissions: IO.Completion.Submission.Queue

        /// The wakeup channel for interrupting poll.
        public let wakeup: IO.Completion.Wakeup.Channel

        /// The bridge for poll thread → actor event handoff.
        public let bridge: IO.Completion.Bridge

        /// The shutdown flag.
        public let shutdownFlag: Shutdown.Flag

        /// Creates a poll loop context.
        public init(
            driver: IO.Completion.Driver,
            handle: consuming IO.Completion.Driver.Handle,
            submissions: IO.Completion.Submission.Queue,
            wakeup: IO.Completion.Wakeup.Channel,
            bridge: IO.Completion.Bridge,
            shutdownFlag: Shutdown.Flag
        ) {
            self.driver = driver
            self.handle = handle
            self.submissions = submissions
            self.wakeup = wakeup
            self.bridge = bridge
            self.shutdownFlag = shutdownFlag
        }
    }
}

// MARK: - Run

extension IO.Completion.PollLoop {
    /// Runs the poll loop until shutdown.
    ///
    /// This is the main entry point for the poll thread. It:
    /// 1. Drains submissions from the queue
    /// 2. Submits them to the driver
    /// 3. Flushes pending submissions
    /// 4. Polls for completion events
    /// 5. Pushes events to the bridge
    /// 6. Repeats until shutdown flag is set
    /// 7. Closes the handle on exit
    ///
    /// ## Ownership
    ///
    /// Consumes the context, including the handle. The handle is closed
    /// on exit, ensuring proper resource cleanup.
    ///
    /// ## Error Handling
    ///
    /// Driver errors during the loop are logged but do not stop the loop.
    /// The loop only exits when the shutdown flag is set.
    ///
    /// - Parameter context: The poll loop context (consumed).
    public static func run(_ context: consuming Context) {
        // Extract resources from context
        let driver = context.driver
        var handle = context.handle
        let submissions = context.submissions
        let bridge = context.bridge
        let shutdownFlag = context.shutdownFlag

        // Pre-allocate buffers
        var submissionBuffer: [IO.Completion.Operation.Storage] = []
        submissionBuffer.reserveCapacity(driver.capabilities.maxSubmissions)

        var eventBuffer: [IO.Completion.Event] = []
        eventBuffer.reserveCapacity(driver.capabilities.maxCompletions)

        // Main loop
        while !shutdownFlag.isSet {
            // 1. Drain submissions
            submissionBuffer.removeAll(keepingCapacity: true)
            _ = submissions.drain(into: &submissionBuffer)

            // 2. Submit to driver
            for storage in submissionBuffer {
                do {
                    try driver.submit(handle, storage: storage)
                } catch {
                    // Log error but continue - individual submission failure
                    // shouldn't stop the loop
                }
            }

            // 3. Flush
            do {
                _ = try driver.flush(handle)
            } catch {
                // Log error but continue
            }

            // 4. Poll for events (blocking)
            eventBuffer.removeAll(keepingCapacity: true)
            do {
                let count = try driver.poll(
                    handle,
                    deadline: nil,  // Block indefinitely until events or wakeup
                    into: &eventBuffer
                )

                // 5. Push events to bridge
                if count > 0 {
                    bridge.push(eventBuffer)
                }
            } catch {
                // Log error but continue - poll failures are often transient
                // (interrupted by signal, etc.)
            }
        }

        // 6. Shutdown: close handle
        driver.close(handle)
    }
}
