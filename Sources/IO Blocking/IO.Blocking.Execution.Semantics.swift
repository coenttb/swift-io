//
//  IO.Blocking.Execution.Semantics.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 06/01/2026.
//

extension IO.Blocking.Execution {
    /// Execution guarantees a lane provides for accepted jobs.
    ///
    /// This enum represents a lattice ordered by strength of guarantee:
    /// ```
    /// guaranteed > bestEffort > abandonOnExecutionTimeout
    /// ```
    ///
    /// When composing lanes (e.g., sharding), use **weakest-wins**: the composite
    /// lane can only promise what all underlying lanes can deliver.
    public enum Semantics: Sendable, Equatable, Comparable {
        /// Once a job is accepted, it will execute to completion.
        ///
        /// - Caller cancellation does not prevent execution (though caller may not observe result).
        /// - Shutdown waits for in-flight operations to complete.
        /// - Enables safe mutation semantics: the operation runs, caller may just not observe result.
        ///
        /// Use for production lanes where operation completion is critical.
        case guaranteed

        /// Accepted jobs may be dropped on shutdown or under resource pressure.
        ///
        /// - No guarantee that accepted work runs.
        /// - Callers cannot rely on "run once accepted" semantics.
        ///
        /// Use for opportunistic work that can be safely discarded.
        case bestEffort

        /// Operations may be abandoned mid-execution on timeout.
        ///
        /// - The caller receives a timeout error, but the operation continues
        ///   running on a detached thread.
        /// - Side effects may outlive the caller.
        /// - Abandoned threads are not joinable and may leak resources.
        ///
        /// **Only suitable for test scenarios** with "pure-ish" or idempotent operations.
        /// Production code should never use this.
        case abandonOnExecutionTimeout

        /// Returns the weaker of two semantics (used for lane composition).
        ///
        /// ```swift
        /// .guaranteed.weakest(.bestEffort) // → .bestEffort
        /// .bestEffort.weakest(.abandonOnExecutionTimeout) // → .abandonOnExecutionTimeout
        /// ```
        public func weakest(_ other: Self) -> Self {
            self > other ? self : other
        }

        // MARK: - Comparable

        public static func < (lhs: Self, rhs: Self) -> Bool {
            lhs.rawValue < rhs.rawValue
        }

        private var rawValue: Int {
            switch self {
            case .guaranteed: 0
            case .bestEffort: 1
            case .abandonOnExecutionTimeout: 2
            }
        }
    }
}
