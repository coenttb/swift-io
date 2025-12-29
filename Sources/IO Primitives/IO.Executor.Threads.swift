//
//  IO.Executor.Threads.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 28/12/2025.
//

import Synchronization

extension IO.Executor {
    /// A sharded pool of serial executors for actor pinning.
    ///
    /// Pools are assigned to executors via round-robin at creation time.
    /// This provides:
    /// - Bounded thread count (default: min(4, processorCount))
    /// - Latency isolation between pools on different shards
    /// - Predictable scheduling topology
    ///
    /// ## Usage
    /// Typically accessed via `IO.Executor.shared`, but can also be instantiated
    /// directly for custom executor pool configurations.
    public final class Threads: Sendable {
        /// Configuration options for the executor pool.
        public struct Options: Sendable {
            /// Number of executor threads in the pool.
            public var count: Int

            /// Creates options with the specified thread count.
            ///
            /// - Parameter count: Number of threads. If nil, defaults to min(4, processorCount).
            public init(count: Int? = nil) {
                self.count = count ?? min(4, IO.Platform.processorCount)
            }
        }

        private let executors: [Thread]
        private let counter: Atomic<UInt64>

        /// Creates a new executor pool with the given options.
        ///
        /// Threads start immediately upon pool creation.
        public init(_ options: Options = .init()) {
            self.executors = (0..<options.count).map { _ in Thread() }
            self.counter = Atomic(0)
        }

        /// The number of executor threads in the pool.
        public var count: Int { executors.count }

        /// Get the next executor using round-robin assignment.
        ///
        /// Each call advances an internal counter, distributing pools evenly
        /// across available executor threads.
        public func next() -> Thread {
            let index = counter.wrappingAdd(1, ordering: .relaxed).oldValue
            return executors[Int(index % UInt64(executors.count))]
        }

        /// Get a specific executor by index.
        ///
        /// Useful for explicit pinning when you want control over which
        /// executor a pool uses.
        ///
        /// - Parameter index: The executor index (wraps around if >= count).
        public func executor(at index: Int) -> Thread {
            executors[index % executors.count]
        }

        /// Shutdown all executor threads in the pool.
        ///
        /// - Precondition: Must be called from a thread that is NOT one of the
        ///   executor threads. The shared pool should generally not be shut down
        ///   during normal operation.
        public func shutdown() {
            for executor in executors {
                executor.shutdown()
            }
        }
    }
}
