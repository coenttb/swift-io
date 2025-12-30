//
//  ContentionBenchmarks.swift
//  swift-io
//
//  Benchmarks measuring behavior under thread contention.
//
//  ## What These Benchmarks Measure
//  - Fairness when tasks exceed thread count
//  - Queue management overhead
//  - Latency distribution under contention
//
//  ## Running
//  swift test -c release --filter ContentionBenchmarks
//

import IO
import NIOPosix
import StandardsTestSupport
import Testing

enum ContentionBenchmarks {
    #TestSuites
}

// MARK: - Moderate Contention (10:1 task:thread ratio)

extension ContentionBenchmarks.Test.Performance {

    @Suite("Moderate Contention (10:1)")
    struct Moderate {

        static let threadCount = 4
        static let taskCount = 40
        static let workMicroseconds = 100

        @Test(
            "swift-io: 40 tasks / 4 threads",
            .timed(iterations: 5, warmup: 2, trackAllocations: false)
        )
        func swiftIO() async throws {
            let lane = IO.Blocking.Lane.threads(.init(workers: Self.threadCount))

            try await withThrowingTaskGroup(of: Void.self) { group in
                for _ in 0..<Self.taskCount {
                    group.addTask {
                        let result: Result<Void, Never> = try await lane.run(deadline: .none) {
                            ThroughputBenchmarks.simulateWork(microseconds: Self.workMicroseconds)
                        }
                        _ = result
                    }
                }
                try await group.waitForAll()
            }

            await lane.shutdown()
        }

        @Test(
            "NIOThreadPool: 40 tasks / 4 threads",
            .timed(iterations: 5, warmup: 2, trackAllocations: false)
        )
        func nio() async throws {
            let pool = NIOThreadPool(numberOfThreads: Self.threadCount)
            pool.start()

            try await withThrowingTaskGroup(of: Void.self) { group in
                for _ in 0..<Self.taskCount {
                    group.addTask {
                        try await pool.runIfActive {
                            ThroughputBenchmarks.simulateWork(microseconds: Self.workMicroseconds)
                        }
                    }
                }
                try await group.waitForAll()
            }

            try await pool.shutdownGracefully()
        }
    }
}

// MARK: - High Contention (100:1 task:thread ratio)

extension ContentionBenchmarks.Test.Performance {

    @Suite("High Contention (100:1)")
    struct High {

        static let threadCount = 4
        static let taskCount = 400
        static let workMicroseconds = 50

        @Test(
            "swift-io: 400 tasks / 4 threads",
            .timed(iterations: 3, warmup: 1, trackAllocations: false)
        )
        func swiftIO() async throws {
            let lane = IO.Blocking.Lane.threads(.init(workers: Self.threadCount))

            try await withThrowingTaskGroup(of: Void.self) { group in
                for _ in 0..<Self.taskCount {
                    group.addTask {
                        let result: Result<Void, Never> = try await lane.run(deadline: .none) {
                            ThroughputBenchmarks.simulateWork(microseconds: Self.workMicroseconds)
                        }
                        _ = result
                    }
                }
                try await group.waitForAll()
            }

            await lane.shutdown()
        }

        @Test(
            "NIOThreadPool: 400 tasks / 4 threads",
            .timed(iterations: 3, warmup: 1, trackAllocations: false)
        )
        func nio() async throws {
            let pool = NIOThreadPool(numberOfThreads: Self.threadCount)
            pool.start()

            try await withThrowingTaskGroup(of: Void.self) { group in
                for _ in 0..<Self.taskCount {
                    group.addTask {
                        try await pool.runIfActive {
                            ThroughputBenchmarks.simulateWork(microseconds: Self.workMicroseconds)
                        }
                    }
                }
                try await group.waitForAll()
            }

            try await pool.shutdownGracefully()
        }
    }
}

// MARK: - Extreme Contention (1000:1 task:thread ratio)

extension ContentionBenchmarks.Test.Performance {

    @Suite("Extreme Contention (1000:1)")
    struct Extreme {

        static let threadCount = 2
        static let taskCount = 2000
        static let workMicroseconds = 10

        @Test(
            "swift-io: 2000 tasks / 2 threads",
            .timed(iterations: 3, warmup: 1, trackAllocations: false)
        )
        func swiftIO() async throws {
            let lane = IO.Blocking.Lane.threads(.init(
                workers: Self.threadCount,
                queueLimit: Self.taskCount,
                acceptanceWaitersLimit: Self.taskCount
            ))

            try await withThrowingTaskGroup(of: Void.self) { group in
                for _ in 0..<Self.taskCount {
                    group.addTask {
                        let result: Result<Void, Never> = try await lane.run(deadline: .none) {
                            ThroughputBenchmarks.simulateWork(microseconds: Self.workMicroseconds)
                        }
                        _ = result
                    }
                }
                try await group.waitForAll()
            }

            await lane.shutdown()
        }

        @Test(
            "NIOThreadPool: 2000 tasks / 2 threads",
            .timed(iterations: 3, warmup: 1, trackAllocations: false)
        )
        func nio() async throws {
            let pool = NIOThreadPool(numberOfThreads: Self.threadCount)
            pool.start()

            try await withThrowingTaskGroup(of: Void.self) { group in
                for _ in 0..<Self.taskCount {
                    group.addTask {
                        try await pool.runIfActive {
                            ThroughputBenchmarks.simulateWork(microseconds: Self.workMicroseconds)
                        }
                    }
                }
                try await group.waitForAll()
            }

            try await pool.shutdownGracefully()
        }
    }
}
