//
//  IO.Blocking.Lane.Abandoning.Options.swift
//  swift-io
//
//  Configuration options for the abandoning lane.
//

extension IO.Blocking.Lane.Abandoning {
    /// Configuration options for the abandoning lane.
    ///
    /// ## Defaults
    /// The defaults are tuned for typical scenarios:
    /// - 4 initial workers (parallel operations)
    /// - 32 max workers (cap on abandoned thread accumulation)
    /// - 30 second execution timeout (generous but finite)
    /// - 64 queue limit (backlog capacity)
    /// - Fail-fast strategy (immediate feedback)
    public struct Options: Sendable {
        /// Worker configuration.
        public var workers: Workers

        /// Execution configuration.
        public var execution: Execution

        /// Queue configuration.
        public var queue: Queue

        /// Backpressure strategy when queue is full.
        ///
        /// - `.failFast`: Return `.queueFull` immediately (recommended)
        /// - `.wait`: Wait for capacity (may delay feedback)
        public var strategy: IO.Backpressure.Strategy

        /// Creates abandoning lane options with explicit values.
        public init(
            workers: Workers = .init(),
            execution: Execution = .init(),
            queue: Queue = .init(),
            strategy: IO.Backpressure.Strategy = .failFast
        ) {
            self.workers = workers
            self.execution = execution
            self.queue = queue
            self.strategy = strategy
        }
    }
}
