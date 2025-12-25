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
    ///
    /// ## Module Ownership
    /// - **IO Blocking**: Owns lane backpressure (`Lane.*` types) because it owns lane queues.
    /// - **IO**: Owns handle backpressure (`Handle.*` types) because it owns handle waiters.
    public enum Backpressure {}
}

// MARK: - Lane Namespace

extension IO.Backpressure {
    /// Namespace for lane-related backpressure types.
    ///
    /// Lane backpressure controls behavior when the lane job queue or
    /// acceptance waiter queue reaches capacity.
    public enum Lane {}
}

extension IO.Backpressure.Lane {
    /// Namespace for queue-full related types.
    public enum QueueFull {}

    /// Namespace for acceptance overflow related types.
    public enum AcceptanceOverflow {}
}

// MARK: - Lane.QueueFull.Context & Decision

extension IO.Backpressure.Lane.QueueFull {
    /// Context describing the state when the lane job queue is full.
    public struct Context: Sendable, Equatable {
        /// Number of jobs currently enqueued.
        public let queueCount: Int

        /// Maximum capacity of the job queue.
        public let queueCapacity: Int

        /// Optional deadline associated with the caller.
        public let deadline: IO.Blocking.Deadline?

        /// Number of tasks waiting for queue capacity.
        public let acceptanceWaitersCount: Int

        /// Maximum capacity of the acceptance waiter queue.
        public let acceptanceWaitersCapacity: Int

        public init(
            queueCount: Int,
            queueCapacity: Int,
            deadline: IO.Blocking.Deadline?,
            acceptanceWaitersCount: Int,
            acceptanceWaitersCapacity: Int
        ) {
            self.queueCount = queueCount
            self.queueCapacity = queueCapacity
            self.deadline = deadline
            self.acceptanceWaitersCount = acceptanceWaitersCount
            self.acceptanceWaitersCapacity = acceptanceWaitersCapacity
        }
    }

    /// Decision returned by `Lane.Behavior.onQueueFull`.
    public enum Decision: Sendable, Equatable {
        /// Suspend and enqueue an acceptance waiter.
        case wait

        /// Fail immediately with the provided failure.
        case fail(IO.Blocking.Failure)
    }
}

// MARK: - Lane.AcceptanceOverflow.Context

extension IO.Backpressure.Lane.AcceptanceOverflow {
    /// Context describing the state when the acceptance waiter queue is full.
    public struct Context: Sendable, Equatable {
        /// Number of waiters currently in the acceptance queue.
        public let waitersCount: Int

        /// Maximum capacity of the acceptance waiter queue.
        public let waitersCapacity: Int

        /// Number of jobs currently enqueued.
        public let queueCount: Int

        /// Maximum capacity of the job queue.
        public let queueCapacity: Int

        public init(
            waitersCount: Int,
            waitersCapacity: Int,
            queueCount: Int,
            queueCapacity: Int
        ) {
            self.waitersCount = waitersCount
            self.waitersCapacity = waitersCapacity
            self.queueCount = queueCount
            self.queueCapacity = queueCapacity
        }
    }
}

// MARK: - Lane.Behavior

extension IO.Backpressure.Lane {
    /// Closure-based behaviour configuration for lane backpressure handling.
    ///
    /// Provides hooks for lane queue-full conditions. Each hook receives
    /// a context describing the current state and returns either a decision
    /// or an error to throw.
    ///
    /// ## Thread Safety
    /// All closures must be `@Sendable`. Behavior is passed across
    /// isolation boundaries and may be invoked from any thread.
    ///
    /// ## Invariants
    /// Closures cannot bypass hard limits. Even if `onQueueFull`
    /// returns `.wait`, the acceptance waiter queue has a hard cap.
    ///
    /// ## Scope
    /// This behavior covers lane-level backpressure only. Handle-level
    /// backpressure is defined in the IO module via `IO.Backpressure.Handle.Behavior`.
    public struct Behavior: Sendable {
        /// Called when the lane job queue is full.
        ///
        /// - Returns: `.wait` to suspend until capacity, or `.fail(...)` to reject immediately.
        public var onQueueFull: @Sendable (QueueFull.Context) -> QueueFull.Decision

        /// Called when acceptance waiter queue is full (hard limit).
        ///
        /// This is always a failure condition to bound memory.
        /// The closure chooses which error to return.
        ///
        /// - Returns: The failure to throw (typically `.overloaded`).
        public var onAcceptanceOverflow: @Sendable (AcceptanceOverflow.Context) -> IO.Blocking.Failure

        /// Creates a behavior with custom hooks.
        public init(
            onQueueFull: @escaping @Sendable (QueueFull.Context) -> QueueFull.Decision,
            onAcceptanceOverflow: @escaping @Sendable (AcceptanceOverflow.Context) -> IO.Blocking.Failure = { _ in .overloaded }
        ) {
            self.onQueueFull = onQueueFull
            self.onAcceptanceOverflow = onAcceptanceOverflow
        }
    }
}

// MARK: - Lane.Behavior Presets

extension IO.Backpressure.Lane.Behavior {
    /// Suspends callers until queue capacity is available.
    public static var wait: Self {
        Self(onQueueFull: { _ in .wait })
    }

    /// Fails immediately when queue is full.
    public static var failFast: Self {
        Self(onQueueFull: { _ in .fail(.queueFull) })
    }
}

// MARK: - Policy

extension IO.Backpressure {
    /// Unified backpressure policy for lane queue types.
    ///
    /// This policy configures:
    /// - **Job queue**: Maximum jobs and behavior when full
    /// - **Acceptance waiter queue**: Maximum waiters and overflow behavior
    ///
    /// ## Error Handling
    /// Lane errors use `IO.Blocking.Failure`:
    /// - `.queueFull` when job queue is full and behavior rejects
    /// - `.overloaded` when acceptance waiter queue is full
    ///
    /// ## Handle Backpressure
    /// Handle waiter limits are configured separately in the IO module
    /// via `IO.Backpressure.Handle.Behavior`. See `IO.Backpressure.Configuration`
    /// for unified configuration.
    public struct Policy: Sendable {
        /// Closure-based behaviour for lane queue-full conditions.
        public var behavior: Lane.Behavior

        // MARK: - Lane Limits

        /// Maximum jobs in lane queue.
        ///
        /// When reached, the behaviour's `onQueueFull` determines whether
        /// to wait or fail.
        public var laneQueueLimit: Int

        /// Maximum tasks waiting for lane queue capacity.
        ///
        /// This is a hard limit to bound memory. When reached, the behaviour's
        /// `onAcceptanceOverflow` is invoked regardless of the queue-full decision.
        public var laneAcceptanceWaitersLimit: Int

        /// Creates a backpressure policy.
        ///
        /// - Parameters:
        ///   - behavior: Closure-based behaviour (default: `.wait`).
        ///   - laneQueueLimit: Max lane queue size (default: 256).
        ///   - laneAcceptanceWaitersLimit: Max lane waiters (default: 4 × laneQueueLimit).
        public init(
            behavior: Lane.Behavior = .wait,
            laneQueueLimit: Int = 256,
            laneAcceptanceWaitersLimit: Int? = nil
        ) {
            self.behavior = behavior
            self.laneQueueLimit = max(1, laneQueueLimit)
            self.laneAcceptanceWaitersLimit = max(1, laneAcceptanceWaitersLimit ?? (4 * self.laneQueueLimit))
        }

        /// Default policy with reasonable limits and wait behaviour.
        public static let `default` = Policy()
    }
}
