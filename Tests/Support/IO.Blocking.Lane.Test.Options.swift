//
//  IO.Blocking.Lane.Test.Options.swift
//  swift-io
//
//  Configuration options for the fault-tolerant test lane.
//

public import IO_Blocking_Threads
public import Kernel

extension IO.Blocking.Lane.Test {
    /// Configuration options for the test lane.
    ///
    /// ## Defaults
    /// The defaults are tuned for typical unit test scenarios:
    /// - 4 initial workers (parallel test operations)
    /// - 32 max workers (cap on abandoned thread accumulation)
    /// - 30 second execution timeout (generous but finite)
    /// - 64 queue limit (backlog capacity)
    /// - Fail-fast strategy (immediate feedback)
    public struct Options: Sendable {
        /// Initial number of worker threads.
        ///
        /// Workers execute blocking operations on dedicated OS threads.
        /// More workers allow more parallel operations but consume more resources.
        public var workers: Kernel.Thread.Count

        /// Maximum number of workers including abandoned ones.
        ///
        /// When a worker is abandoned due to timeout, a replacement is spawned.
        /// This limit caps the total number of threads (live + abandoned) to
        /// prevent unbounded resource consumption from hung operations.
        ///
        /// When the cap is reached:
        /// - Timeouts still function (caller resumes with timeout error)
        /// - No replacement is spawned
        /// - Queue submissions may fail with `.maxWorkersReached`
        public var maxWorkers: Kernel.Thread.Count

        /// Maximum time an operation may execute before being abandoned.
        ///
        /// If an operation exceeds this timeout:
        /// - The caller receives a timeout error
        /// - The operation continues on the abandoned thread
        /// - A replacement worker is spawned (if under maxWorkers)
        ///
        /// Choose a value that catches genuinely hung operations without
        /// triggering on legitimately slow operations.
        public var executionTimeout: Duration

        /// Maximum number of pending jobs in the queue.
        ///
        /// When the queue is full, behavior depends on `strategy`:
        /// - `.failFast`: Immediate rejection with `.queueFull`
        /// - `.wait`: Block until capacity available (bounded by deadline)
        public var queueLimit: Int

        /// Backpressure strategy when queue is full.
        ///
        /// - `.failFast`: Return `.queueFull` immediately (recommended for tests)
        /// - `.wait`: Wait for capacity (may delay test feedback)
        public var strategy: IO.Backpressure.Strategy

        /// Creates test lane options with explicit values.
        public init(
            workers: Kernel.Thread.Count = 4,
            maxWorkers: Kernel.Thread.Count = 32,
            executionTimeout: Duration = .seconds(30),
            queueLimit: Int = 64,
            strategy: IO.Backpressure.Strategy = .failFast
        ) {
            self.workers = workers
            self.maxWorkers = maxWorkers
            self.executionTimeout = executionTimeout
            self.queueLimit = queueLimit
            self.strategy = strategy
        }
    }
}
