//
//  LifecycleBenchmarks.swift
//  swift-io
//
//  Benchmarks measuring pool/lane creation and shutdown costs.
//  These are separated from steady-state benchmarks to avoid contamination.
//
//  ## What These Benchmarks Measure
//  - Pool/lane creation time (thread spawning, initialization)
//  - Shutdown time (graceful drain, thread join)
//
//  ## Running
//  swift test -c release --filter LifecycleBenchmarks
//

import Dimension
import IO
import NIOPosix
import StandardsTestSupport
import Testing

enum LifecycleBenchmarks {
    #TestSuites
}

// MARK: - Creation Cost

extension LifecycleBenchmarks.Test.Performance {

    @Suite("Pool Creation")
    struct Creation {

        static var threadCount: Int { ThreadPoolFixture.defaultThreadCount }

        @Test(
            "swift-io: lane creation",
            .timed(iterations: 20, warmup: 5, trackAllocations: true)
        )
        func swiftIOCreation() async {
            let lane = IO.Blocking.Lane.threads(
                .init(workers: IO.Thread.Count(Self.threadCount))
            )
            // Ensure threads are started
            _ = try? await lane.run(deadline: .none) { () }
            await lane.shutdown()
        }

        @Test(
            "NIOThreadPool: pool creation",
            .timed(iterations: 20, warmup: 5, trackAllocations: true)
        )
        func nioCreation() async throws {
            let pool = NIOThreadPool(numberOfThreads: Self.threadCount)
            pool.start()
            // Ensure threads are started
            _ = try await pool.runIfActive { () }
            try await pool.shutdownGracefully()
        }
    }
}

// MARK: - Shutdown Cost (Idle)

extension LifecycleBenchmarks.Test.Performance {

    @Suite("Pool Shutdown (Idle)")
    struct ShutdownIdle {

        static var threadCount: Int { ThreadPoolFixture.defaultThreadCount }

        @Test(
            "swift-io: shutdown idle pool",
            .timed(iterations: 20, warmup: 5, trackAllocations: false)
        )
        func swiftIOShutdownIdle() async {
            let lane = IO.Blocking.Lane.threads(
                .init(workers: IO.Thread.Count(Self.threadCount))
            )
            // Warm up - ensure threads are started and idle
            _ = try? await lane.run(deadline: .none) { () }
            await lane.shutdown()
        }

        @Test(
            "NIOThreadPool: shutdown idle pool",
            .timed(iterations: 20, warmup: 5, trackAllocations: false)
        )
        func nioShutdownIdle() async throws {
            let pool = NIOThreadPool(numberOfThreads: Self.threadCount)
            pool.start()
            // Warm up - ensure threads are started and idle
            _ = try await pool.runIfActive { () }
            try await pool.shutdownGracefully()
        }
    }
}
