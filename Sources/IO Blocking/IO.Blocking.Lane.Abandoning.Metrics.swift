//
//  IO.Blocking.Lane.Abandoning.Metrics.swift
//  swift-io
//
//  Metrics snapshot for the abandoning lane.
//

extension IO.Blocking.Lane.Abandoning {
    /// Metrics snapshot for the abandoning lane.
    public struct Metrics: Sendable {
        /// Worker-related metrics.
        public var workers: Workers

        /// Queue-related metrics.
        public var queue: Queue

        /// Totals since creation.
        public var total: Total

        public init(workers: Workers, queue: Queue, total: Total) {
            self.workers = workers
            self.queue = queue
            self.total = total
        }
    }
}
