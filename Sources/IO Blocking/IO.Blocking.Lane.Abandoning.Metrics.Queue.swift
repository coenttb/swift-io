//
//  IO.Blocking.Lane.Abandoning.Metrics.Queue.swift
//  swift-io
//
//  Queue metrics for the abandoning lane.
//

extension IO.Blocking.Lane.Abandoning.Metrics {
    /// Queue-related metrics.
    public struct Queue: Sendable {
        /// Current queue depth.
        public var depth: Int

        public init(depth: Int) {
            self.depth = depth
        }
    }
}
