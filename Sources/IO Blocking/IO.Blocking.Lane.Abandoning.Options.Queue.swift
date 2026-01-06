//
//  IO.Blocking.Lane.Abandoning.Options.Queue.swift
//  swift-io
//
//  Queue configuration for the abandoning lane.
//

extension IO.Blocking.Lane.Abandoning.Options {
    /// Queue-related configuration.
    public struct Queue: Sendable {
        /// Maximum number of pending jobs in the queue.
        ///
        /// When the queue is full, behavior depends on `strategy`:
        /// - `.failFast`: Immediate rejection with `.queueFull`
        /// - `.wait`: Block until capacity available (bounded by deadline)
        public var limit: Int

        public init(limit: Int = 64) {
            self.limit = limit
        }
    }
}
