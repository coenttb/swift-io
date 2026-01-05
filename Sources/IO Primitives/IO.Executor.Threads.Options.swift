//
//  IO.Executor.Threads.Options.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 28/12/2025.
//

public import Dimension

extension IO.Executor.Threads {
    /// Configuration options for the executor pool.
    public struct Options: Sendable {
        /// Number of executor threads in the pool.
        public var count: IO.Thread.Count

        /// Creates options with the specified thread count.
        ///
        /// - Parameter count: Number of threads. If nil, defaults to min(4, processorCount).
        public init(count: IO.Thread.Count? = nil) {
            self.count = count ?? min(
                IO.Thread.Count(4),
                IO.Thread.Count(IO.Platform.processorCount)
            )
        }
    }
}
