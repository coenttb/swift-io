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

        /// Backpressure policy when queue is full.
        public var backpressure: Backpressure

        /// Creates options with the given values.
        ///
        /// - Parameters:
        ///   - workers: Number of workers (default: processor count).
        ///   - queueLimit: Maximum queue size (default: 256).
        ///   - backpressure: Backpressure policy (default: `.suspend`).
        public init(
            workers: Int? = nil,
            queueLimit: Int = 256,
            backpressure: Backpressure = .suspend
        ) {
            self.workers = max(1, workers ?? IO.Blocking.Threads.processorCount)
            self.queueLimit = max(1, queueLimit)
            self.backpressure = backpressure
        }
    }
}
