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

        /// Unified backpressure policy.
        ///
        /// Configures queue limits and backpressure strategy.
        /// See `IO.Backpressure.Policy` for details.
        public var policy: IO.Backpressure.Policy

        // MARK: - Convenience Accessors

        /// Maximum number of jobs in the queue.
        public var queueLimit: Int {
            get { policy.laneQueueLimit }
            set { policy.laneQueueLimit = newValue }
        }

        /// Maximum number of acceptance waiters (tasks waiting for queue capacity).
        public var acceptanceWaitersLimit: Int {
            get { policy.laneAcceptanceWaitersLimit }
            set { policy.laneAcceptanceWaitersLimit = newValue }
        }

        /// Backpressure strategy when queue is full.
        public var strategy: IO.Backpressure.Strategy {
            get { policy.strategy }
            set { policy.strategy = newValue }
        }

        // MARK: - Initializers

        /// Creates options with a unified backpressure policy.
        ///
        /// - Parameters:
        ///   - workers: Number of workers (default: processor count).
        ///   - policy: Backpressure policy (default: `.default`).
        public init(
            workers: Int? = nil,
            policy: IO.Backpressure.Policy = .default
        ) {
            self.workers = max(1, workers ?? IO.Platform.processorCount)
            self.policy = policy
        }

        /// Creates options with individual parameters.
        ///
        /// - Parameters:
        ///   - workers: Number of workers (default: processor count).
        ///   - queueLimit: Maximum queue size (default: 256).
        ///   - acceptanceWaitersLimit: Maximum waiters (default: 4 × queueLimit).
        ///   - backpressure: Backpressure strategy (default: `.suspend`).
        public init(
            workers: Int? = nil,
            queueLimit: Int = 256,
            acceptanceWaitersLimit: Int? = nil,
            backpressure: Backpressure = .suspend
        ) {
            self.workers = max(1, workers ?? IO.Platform.processorCount)
            self.policy = IO.Backpressure.Policy(
                strategy: backpressure.strategy,
                laneQueueLimit: queueLimit,
                laneAcceptanceWaitersLimit: acceptanceWaitersLimit
            )
        }
    }
}
