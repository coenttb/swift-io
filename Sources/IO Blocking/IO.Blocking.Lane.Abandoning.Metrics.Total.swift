//
//  IO.Blocking.Lane.Abandoning.Metrics.Total.swift
//  swift-io
//
//  Total metrics for the abandoning lane.
//

extension IO.Blocking.Lane.Abandoning.Metrics {
    /// Total counts since creation.
    public struct Total: Sendable {
        /// Total operations completed successfully.
        public var completed: UInt64

        /// Total operations abandoned due to timeout.
        public var abandoned: UInt64

        public init(completed: UInt64, abandoned: UInt64) {
            self.completed = completed
            self.abandoned = abandoned
        }
    }
}
