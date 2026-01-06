//
//  IO.Blocking.Lane.Abandoning.Options.Workers.swift
//  swift-io
//
//  Worker configuration for the abandoning lane.
//

extension IO.Blocking.Lane.Abandoning.Options {
    /// Worker-related configuration.
    public struct Workers: Sendable {
        /// Initial number of worker threads.
        ///
        /// Workers execute blocking operations on dedicated OS threads.
        /// More workers allow more parallel operations but consume more resources.
        public var initial: Kernel.Thread.Count

        /// Maximum number of workers including abandoned ones.
        ///
        /// When a worker is abandoned due to timeout, a replacement is spawned.
        /// This limit caps the total number of threads (live + abandoned) to
        /// prevent unbounded resource consumption from hung operations.
        ///
        /// When the cap is reached:
        /// - Timeouts still function (caller resumes with timeout error)
        /// - No replacement is spawned
        /// - Queue submissions may fail with `.overloaded`
        public var max: Kernel.Thread.Count

        public init(initial: Kernel.Thread.Count = 4, max: Kernel.Thread.Count = 32) {
            self.initial = initial
            self.max = max
        }
    }
}
