//
//  Fixtures.swift
//  swift-io
//
//  Shared fixtures for benchmark comparisons.
//

import Dimension
import Foundation
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

    /// Configurable via IO_BENCH_THREADS environment variable.
    static var defaultThreadCount: Int {
        if let str = ProcessInfo.processInfo.environment["IO_BENCH_THREADS"],
           let count = Int(str), count > 0 {
            return count
        }
        return 4
    }

    static let shared: ThreadPoolFixture = make()

    /// Create a new fixture with specified thread count.
    static func make(threadCount: Int = defaultThreadCount) -> ThreadPoolFixture {
        let lane = IO.Blocking.Lane.threads(.init(workers: Kernel.Thread.Count(threadCount)))
        let nio = NIOThreadPool(numberOfThreads: threadCount)
        nio.start()
        return ThreadPoolFixture(swiftIOLane: lane, nio: nio, threadCount: threadCount)
    }

    private init(swiftIOLane: IO.Blocking.Lane, nio: NIOThreadPool, threadCount: Int) {
        self.swiftIOLane = swiftIOLane
        self.nio = nio
        self.threadCount = threadCount
    }

    /// Ensures both pools have processed through all workers.
    ///
    /// Submits threadCount no-ops to each pool and awaits all, ensuring
    /// every worker has had an opportunity to process at least one task.
    /// This is materially stronger than a single no-op fence.
    ///
    /// - Note: This still doesn't guarantee "no in-flight tasks" but is
    ///   sufficient for establishing a clean pre-state in edge/capability tests.
    func quiesce() async {
        // swift-io: threadCount round-trips
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<threadCount {
                group.addTask {
                    _ = try? await self.swiftIOLane.run(deadline: .none) { () }
                }
            }
        }
        // NIO: threadCount round-trips
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<threadCount {
                group.addTask {
                    _ = try? await self.nio.runIfActive { () }
                }
            }
        }
    }

    /// Shuts down both pools. Call at end of benchmark suite if needed.
    func shutdown() async {
        await swiftIOLane.shutdown()
        try? await nio.shutdownGracefully()
    }
}
