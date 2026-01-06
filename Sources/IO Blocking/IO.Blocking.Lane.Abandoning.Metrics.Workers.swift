//
//  IO.Blocking.Lane.Abandoning.Metrics.Workers.swift
//  swift-io
//
//  Worker metrics for the abandoning lane.
//

extension IO.Blocking.Lane.Abandoning.Metrics {
    /// Worker-related metrics.
    public struct Workers: Sendable {
        /// Number of workers that have been abandoned due to timeout.
        public var abandoned: Int

        /// Number of currently active workers (not abandoned).
        public var active: Int

        /// Total number of workers spawned since creation.
        public var spawned: Int

        public init(abandoned: Int, active: Int, spawned: Int) {
            self.abandoned = abandoned
            self.active = active
            self.spawned = spawned
        }
    }
}
