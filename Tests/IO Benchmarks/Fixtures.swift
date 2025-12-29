//
//  Fixtures.swift
//  swift-io
//
//  Shared fixtures for benchmark comparisons.
//

import IO
import NIOCore
import NIOPosix

/// Shared fixture providing pre-configured thread pools for both swift-io and NIO.
///
/// Both pools use the same thread count for fair comparison.
final class ThreadPoolFixture: @unchecked Sendable {
    let swiftIOLane: IO.Blocking.Lane
    let nio: NIOThreadPool
    let threadCount: Int

    static let shared: ThreadPoolFixture = {
        let count = 4
        let lane = IO.Blocking.Lane.threads(.init(workers: count))
        let nio = NIOThreadPool(numberOfThreads: count)
        nio.start()
        return ThreadPoolFixture(swiftIOLane: lane, nio: nio, threadCount: count)
    }()

    private init(swiftIOLane: IO.Blocking.Lane, nio: NIOThreadPool, threadCount: Int) {
        self.swiftIOLane = swiftIOLane
        self.nio = nio
        self.threadCount = threadCount
    }

    /// Shuts down both pools. Call at end of benchmark suite if needed.
    func shutdown() async {
        await swiftIOLane.shutdown()
        try? await nio.shutdownGracefully()
    }
}
