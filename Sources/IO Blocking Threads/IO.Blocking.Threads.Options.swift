//
//  IO.Blocking.Threads.Options.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 24/12/2025.
//

public import Dimension
public import Kernel

extension IO.Blocking.Threads {
    /// Configuration options for the Threads lane.
    public struct Options: Sendable {
        /// Number of worker threads.
        public var workers: Kernel.Thread.Count

        /// Unified backpressure policy.
        ///
        /// Configures queue limits and backpressure strategy.
        /// See `IO.Backpressure.Policy` for details.
        public var policy: IO.Backpressure.Policy

        /// Job scheduling order (FIFO or LIFO).
        ///
        /// ## FIFO (default)
        /// Jobs are processed in submission order. Fair scheduling.
        ///
        /// ## LIFO
        /// Most recently submitted jobs are processed first. Better cache locality
        /// for CPU-bound work (10-20% improvement typical).
        ///
        /// ## Fairness Warning
        /// LIFO can starve older tasks under sustained load. Intended for
        /// short-lived homogeneous work, not fairness-critical workloads.
        public var scheduling: Scheduling

        /// Callback for queue state transitions (optional).
        ///
        /// ## Edge-Triggered Semantics
        /// Only invoked when state actually changes, not on every operation.
        ///
        /// ## Out-of-Lock Delivery
        /// The callback is invoked **after** the lock is released, never while
        /// holding the lock. This prevents recursion, deadlock, and tail latency.
        ///
        /// ## Warning
        /// Callback must be fast and non-blocking; it is invoked on
        /// enqueue/dequeue code paths and will affect throughput.
        public var onStateTransition: (@Sendable (State.Transition) -> Void)?

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
        ///   - scheduling: Job scheduling order (default: `.fifo`).
        ///   - onStateTransition: Callback for queue state transitions (optional).
        public init(
            workers: Kernel.Thread.Count? = nil,
            policy: IO.Backpressure.Policy = .default,
            scheduling: Scheduling = .fifo,
            onStateTransition: (@Sendable (State.Transition) -> Void)? = nil
        ) {
            self.workers = max(
                Kernel.Thread.Count(1),
                workers ?? Kernel.Thread.Count(Kernel.System.processorCount)
            )
            self.policy = policy
            self.scheduling = scheduling
            self.onStateTransition = onStateTransition
        }

        /// Creates options with individual parameters.
        ///
        /// - Parameters:
        ///   - workers: Number of workers (default: processor count).
        ///   - queueLimit: Maximum queue size (default: 256).
        ///   - acceptanceWaitersLimit: Maximum waiters (default: 4 × queueLimit).
        ///   - backpressure: Backpressure strategy (default: `.wait`).
        ///   - scheduling: Job scheduling order (default: `.fifo`).
        ///   - onStateTransition: Callback for queue state transitions (optional).
        public init(
            workers: Kernel.Thread.Count? = nil,
            queueLimit: Int = 256,
            acceptanceWaitersLimit: Int? = nil,
            backpressure: IO.Backpressure.Strategy = .wait,
            scheduling: Scheduling = .fifo,
            onStateTransition: (@Sendable (State.Transition) -> Void)? = nil
        ) {
            self.workers = max(
                Kernel.Thread.Count(1),
                workers ?? Kernel.Thread.Count(Kernel.System.processorCount)
            )
            self.policy = IO.Backpressure.Policy(
                strategy: backpressure,
                laneQueueLimit: queueLimit,
                laneAcceptanceWaitersLimit: acceptanceWaitersLimit
            )
            self.scheduling = scheduling
            self.onStateTransition = onStateTransition
        }
    }
}
