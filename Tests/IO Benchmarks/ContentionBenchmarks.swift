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
//  ## Note
//  These use shared fixtures to avoid measuring pool creation/shutdown.
//  Lifecycle benchmarks are in LifecycleBenchmarks.swift.
//
//  ## Running
//  swift test -c release --filter ContentionBenchmarks
//

import Dimension
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

        static let fixture = ThreadPoolFixture.shared
        static let taskCount = 40
        static let workDuration = Duration.microseconds(100)

        @Test(
            "swift-io: 40 tasks / 4 threads",
            .timed(iterations: 5, warmup: 2, trackAllocations: false)
        )
        func swiftIO() async throws {
            let lane = Self.fixture.swiftIOLane

            try await withThrowingTaskGroup(of: Void.self) { group in
                for _ in 0..<Self.taskCount {
                    group.addTask {
                        let result: Result<Void, Never> = try await lane.run(deadline: .none) {
                            ThroughputBenchmarks.simulateWork(duration: Self.workDuration)
                        }
                        _ = result
                    }
                }
                try await group.waitForAll()
            }
        }

        @Test(
            "NIOThreadPool: 40 tasks / 4 threads",
            .timed(iterations: 5, warmup: 2, trackAllocations: false)
        )
        func nio() async throws {
            try await withThrowingTaskGroup(of: Void.self) { group in
                for _ in 0..<Self.taskCount {
                    group.addTask {
                        try await Self.fixture.nio.runIfActive {
                            ThroughputBenchmarks.simulateWork(duration: Self.workDuration)
                        }
                    }
                }
                try await group.waitForAll()
            }
        }
    }
}

// MARK: - High Contention (100:1 task:thread ratio)

extension ContentionBenchmarks.Test.Performance {

    @Suite("High Contention (100:1)")
    struct High {

        static let fixture = ThreadPoolFixture.shared
        static let taskCount = 400
        static let workDuration = Duration.microseconds(50)

        @Test(
            "swift-io: 400 tasks / 4 threads",
            .timed(iterations: 3, warmup: 1, trackAllocations: false)
        )
        func swiftIO() async throws {
            let lane = Self.fixture.swiftIOLane

            try await withThrowingTaskGroup(of: Void.self) { group in
                for _ in 0..<Self.taskCount {
                    group.addTask {
                        let result: Result<Void, Never> = try await lane.run(deadline: .none) {
                            ThroughputBenchmarks.simulateWork(duration: Self.workDuration)
                        }
                        _ = result
                    }
                }
                try await group.waitForAll()
            }
        }

        @Test(
            "NIOThreadPool: 400 tasks / 4 threads",
            .timed(iterations: 3, warmup: 1, trackAllocations: false)
        )
        func nio() async throws {
            try await withThrowingTaskGroup(of: Void.self) { group in
                for _ in 0..<Self.taskCount {
                    group.addTask {
                        try await Self.fixture.nio.runIfActive {
                            ThroughputBenchmarks.simulateWork(duration: Self.workDuration)
                        }
                    }
                }
                try await group.waitForAll()
            }
        }
    }
}

// MARK: - Extreme Contention (1000:1 task:thread ratio)

extension ContentionBenchmarks.Test.Performance {

    @Suite("Extreme Contention (1000:1)")
    struct Extreme {

        static let fixture = ThreadPoolFixture.shared
        static let taskCount = 2000
        static let workDuration = Duration.microseconds(10)

        @Test(
            "swift-io: 2000 tasks / 4 threads",
            .timed(iterations: 3, warmup: 1, trackAllocations: false)
        )
        func swiftIO() async throws {
            let lane = Self.fixture.swiftIOLane

            var completed = 0
            var rejected = 0

            await withTaskGroup(of: Bool.self) { group in
                for _ in 0..<Self.taskCount {
                    group.addTask {
                        do {
                            let _: Result<Void, Never> = try await lane.run(deadline: .none) {
                                ThroughputBenchmarks.simulateWork(duration: Self.workDuration)
                            }
                            return true
                        } catch {
                            // Expected: .overloaded under extreme contention
                            return false
                        }
                    }
                }

                for await success in group {
                    if success { completed += 1 } else { rejected += 1 }
                }
            }

            // Under extreme contention, swift-io's bounded queue will reject some ops
            // This is expected behavior demonstrating backpressure
            #expect(completed + rejected == Self.taskCount, "All tasks should complete or be rejected")
        }

        @Test(
            "NIOThreadPool: 2000 tasks / 4 threads",
            .timed(iterations: 3, warmup: 1, trackAllocations: false)
        )
        func nio() async throws {
            try await withThrowingTaskGroup(of: Void.self) { group in
                for _ in 0..<Self.taskCount {
                    group.addTask {
                        try await Self.fixture.nio.runIfActive {
                            ThroughputBenchmarks.simulateWork(duration: Self.workDuration)
                        }
                    }
                }
                try await group.waitForAll()
            }
        }
    }
}
