//
//  IO.Executor.Threads.Options.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 28/12/2025.
//

extension IO.Executor.Threads {
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
}
