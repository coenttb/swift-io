//
//  BackpressureBenchmarks.swift
//  swift-io
//
//  Benchmarks measuring backpressure behavior when queues are full.
//
//  ## What These Benchmarks Measure
//  - Time to reject when queue is full (failFast)
//  - Time to resume when queue has capacity (wait)
//  - Memory behavior under sustained load
//
//  ## Running
//  swift test -c release --filter BackpressureBenchmarks
//
//  ## Note
//  NIOThreadPool doesn't have explicit backpressure - it uses unbounded queues.
//  These benchmarks primarily characterize swift-io behavior and show the
//  difference in backpressure strategies.
//

import IO
import NIOPosix
import StandardsTestSupport
import Testing

enum BackpressureBenchmarks {
    #TestSuites
}

// MARK: - FailFast Strategy

extension BackpressureBenchmarks.Test.Performance {

    @Suite("FailFast Backpressure")
    struct FailFast {

        static let queueLimit = 16
        static let threadCount = 2

        @Test(
            "swift-io: reject when queue full",
            .timed(iterations: 10, warmup: 2, trackAllocations: false)
        )
        func rejectWhenFull() async throws {
            let options = IO.Blocking.Threads.Options(
                workers: Self.threadCount,
                policy: IO.Backpressure.Policy(
                    strategy: .failFast,
                    laneQueueLimit: Self.queueLimit
                )
            )
            let lane = IO.Blocking.Lane.threads(options)

            let fillCount = Self.queueLimit + Self.threadCount
            var accepted = 0
            var rejected = 0

            await withTaskGroup(of: Bool.self) { group in
                for _ in 0..<(fillCount + 10) {
                    group.addTask {
                        do {
                            let result: Result<Bool, Never> = try await lane.run(deadline: .none) {
                                ThroughputBenchmarks.simulateWork(microseconds: 1000)
                                return true
                            }
                            switch result {
                            case .success:
                                return true
                            }
                        } catch {
                            return false
                        }
                    }
                }

                for await wasAccepted in group {
                    if wasAccepted {
                        accepted += 1
                    } else {
                        rejected += 1
                    }
                }
            }

            await lane.shutdown()

            #expect(rejected > 0, "Expected some operations to be rejected")
        }
    }
}

// MARK: - Wait Strategy

extension BackpressureBenchmarks.Test.Performance {

    @Suite("Wait Backpressure")
    struct Wait {

        static let queueLimit = 16
        static let threadCount = 2

        @Test(
            "swift-io: suspend until capacity",
            .timed(iterations: 5, warmup: 1, trackAllocations: false)
        )
        func suspendUntilCapacity() async throws {
            let options = IO.Blocking.Threads.Options(
                workers: Self.threadCount,
                policy: IO.Backpressure.Policy(
                    strategy: .wait,
                    laneQueueLimit: Self.queueLimit
                )
            )
            let lane = IO.Blocking.Lane.threads(options)

            let totalOps = Self.queueLimit * 2

            try await withThrowingTaskGroup(of: Void.self) { group in
                for _ in 0..<totalOps {
                    group.addTask {
                        let result: Result<Void, Never> = try await lane.run(deadline: .none) {
                            ThroughputBenchmarks.simulateWork(microseconds: 100)
                        }
                        _ = result
                    }
                }
                try await group.waitForAll()
            }

            await lane.shutdown()
        }
    }
}

// MARK: - Sustained Load

extension BackpressureBenchmarks.Test.Performance {

    @Suite("Sustained Load")
    struct Sustained {

        static let queueLimit = 32
        static let threadCount = 4
        static let duration = 100
        static let submissionRate = 10

        @Test(
            "swift-io: sustained load with wait policy",
            .timed(iterations: 3, warmup: 1, trackAllocations: false)
        )
        func swiftIOSustained() async throws {
            let options = IO.Blocking.Threads.Options(
                workers: Self.threadCount,
                policy: IO.Backpressure.Policy(
                    strategy: .wait,
                    laneQueueLimit: Self.queueLimit
                )
            )
            let lane = IO.Blocking.Lane.threads(options)

            let totalOps = Self.duration * Self.submissionRate

            try await withThrowingTaskGroup(of: Void.self) { group in
                for _ in 0..<totalOps {
                    group.addTask {
                        let result: Result<Void, Never> = try await lane.run(deadline: .none) {
                            ThroughputBenchmarks.simulateWork(microseconds: 50)
                        }
                        _ = result
                    }
                }
                try await group.waitForAll()
            }

            await lane.shutdown()
        }

        @Test(
            "NIOThreadPool: sustained load (unbounded)",
            .timed(iterations: 3, warmup: 1, trackAllocations: false)
        )
        func nioSustained() async throws {
            let pool = NIOThreadPool(numberOfThreads: Self.threadCount)
            pool.start()

            let totalOps = Self.duration * Self.submissionRate

            try await withThrowingTaskGroup(of: Void.self) { group in
                for _ in 0..<totalOps {
                    group.addTask {
                        try await pool.runIfActive {
                            ThroughputBenchmarks.simulateWork(microseconds: 50)
                        }
                    }
                }
                try await group.waitForAll()
            }

            try await pool.shutdownGracefully()
        }
    }
}
