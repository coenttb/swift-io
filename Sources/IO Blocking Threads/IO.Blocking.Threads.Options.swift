//
//  IO.Blocking.Threads.Options.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 24/12/2025.
//

extension IO.Blocking.Threads {
    /// Configuration options for the Threads lane.
    public struct Options: Sendable {
        /// Number of worker threads.
        public var workers: Int

        /// Maximum number of jobs in the queue.
        public var queueLimit: Int

        /// Maximum number of acceptance waiters (tasks waiting for queue capacity).
        ///
        /// When this limit is reached, new operations fail immediately with
        /// `.overloaded` instead of suspending. This provides bounded memory
        /// usage under load.
        ///
        /// Default: 4 × queueLimit
        public var acceptanceWaitersLimit: Int

        /// Backpressure policy when queue is full.
        public var backpressure: Backpressure

        /// Creates options with the given values.
        ///
        /// - Parameters:
        ///   - workers: Number of workers (default: processor count).
        ///   - queueLimit: Maximum queue size (default: 256).
        ///   - acceptanceWaitersLimit: Maximum waiters (default: 4 × queueLimit).
        ///   - backpressure: Backpressure policy (default: `.suspend`).
        public init(
            workers: Int? = nil,
            queueLimit: Int = 256,
            acceptanceWaitersLimit: Int? = nil,
            backpressure: Backpressure = .suspend
        ) {
            self.workers = max(1, workers ?? IO.Blocking.Threads.processorCount)
            self.queueLimit = max(1, queueLimit)
            self.acceptanceWaitersLimit = max(1, acceptanceWaitersLimit ?? (4 * self.queueLimit))
            self.backpressure = backpressure
        }
    }
}
