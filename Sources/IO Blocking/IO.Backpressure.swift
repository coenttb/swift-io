//
//  IO.Backpressure.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 24/12/2025.
//

extension IO {
    /// Namespace for backpressure configuration.
    ///
    /// Backpressure controls how the system behaves when queues reach capacity.
    /// This unified configuration applies consistently across layers while
    /// allowing separate numeric limits for different queue types.
    public enum Backpressure {}
}

extension IO.Backpressure {
    /// Strategy for handling queue-full conditions.
    public enum Strategy: Sendable, Equatable {
        /// Suspend the caller until capacity is available.
        ///
        /// Bounded by deadline if provided.
        case wait

        /// Fail immediately when queue is full.
        ///
        /// Throws the appropriate error for the layer:
        /// - Lane: `.queueFull`
        /// - Handle: `.waitersFull`
        case failFast
    }
}

extension IO.Backpressure {
    /// Unified backpressure policy for all queue types.
    ///
    /// This policy configures:
    /// - **Lane queues:** Job queue and acceptance waiter queue
    /// - **Handle queues:** Per-handle waiter queue
    ///
    /// ## Error Handling
    /// Each layer maintains its own error type:
    /// - `IO.Blocking.Failure.queueFull` / `.overloaded` for lane
    /// - `IO.Handle.Error.waitersFull` for handles
    ///
    /// These are kept separate intentionally - see ARCHITECTURE.md.
    public struct Policy: Sendable, Equatable {
        /// Strategy when queues are full.
        public var strategy: Strategy

        // MARK: - Lane Limits

        /// Maximum jobs in lane queue.
        ///
        /// When reached with `.failFast`: throws `IO.Blocking.Failure.queueFull`
        /// When reached with `.wait`: caller suspends until capacity
        public var laneQueueLimit: Int

        /// Maximum tasks waiting for lane queue capacity.
        ///
        /// This is a hard limit to bound memory. When reached, new operations
        /// fail with `IO.Blocking.Failure.overloaded` regardless of strategy.
        public var laneAcceptanceWaitersLimit: Int

        // MARK: - Handle Limits

        /// Maximum tasks waiting per handle.
        ///
        /// When reached: throws `IO.Handle.Error.waitersFull`
        /// This is always fail-fast to prevent unbounded per-handle memory.
        public var handleWaitersLimit: Int

        /// Creates a backpressure policy.
        ///
        /// - Parameters:
        ///   - strategy: How to handle queue-full conditions (default: `.wait`).
        ///   - laneQueueLimit: Max lane queue size (default: 256).
        ///   - laneAcceptanceWaitersLimit: Max lane waiters (default: 4 × laneQueueLimit).
        ///   - handleWaitersLimit: Max waiters per handle (default: 64).
        public init(
            strategy: Strategy = .wait,
            laneQueueLimit: Int = 256,
            laneAcceptanceWaitersLimit: Int? = nil,
            handleWaitersLimit: Int = 64
        ) {
            self.strategy = strategy
            self.laneQueueLimit = max(1, laneQueueLimit)
            self.laneAcceptanceWaitersLimit = max(1, laneAcceptanceWaitersLimit ?? (4 * self.laneQueueLimit))
            self.handleWaitersLimit = max(1, handleWaitersLimit)
        }

        /// Default policy with reasonable limits.
        public static let `default` = Policy()
    }
}
