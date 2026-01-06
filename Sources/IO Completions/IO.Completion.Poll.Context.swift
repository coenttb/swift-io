//
//  IO.Completion.Poll.Context.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 31/12/2025.
//

extension IO.Completion.Poll {
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
    /// to the poll thread via `Kernel.Handoff.Cell`.
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
