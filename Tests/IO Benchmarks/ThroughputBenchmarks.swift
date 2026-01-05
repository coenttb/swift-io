//
//  ThroughputBenchmarks.swift
//  swift-io
//
//  Benchmarks measuring throughput with simulated blocking work.
//
//  ## What These Benchmarks Measure
//  - Operations per second with actual work
//  - Thread utilization efficiency
//  - Scheduling overhead under load
//
//  ## Running
//  swift test -c release --filter ThroughputBenchmarks
//

import IO
import NIOPosix
import StandardsTestSupport
import Testing

enum ThroughputBenchmarks {
    #TestSuites
}

// MARK: - Helpers

extension ThroughputBenchmarks {
    /// Simulates blocking work by spinning until deadline.
    ///
    /// Uses `ContinuousClock` for accurate, machine-independent timing.
    /// Clock is checked every 64 iterations to bound overhead.
    @inline(never)
    static func simulateWork(duration: Duration) {
        let deadline = ContinuousClock.now.advanced(by: duration)
        var sum = 0
        var checkCounter = 0
        while true {
            sum &+= checkCounter
            checkCounter += 1
            if checkCounter & 63 == 0 {  // Check every 64 iterations
                if ContinuousClock.now >= deadline { break }
            }
        }
        withExtendedLifetime(sum) {}
    }
}

// MARK: - Work Simulator Baseline

extension ThroughputBenchmarks.Test.Performance {

    /// Validates that simulateWork() produces accurate timing.
    /// Run these to sanity-check timing on your machine.
    @Suite("Work Simulator Baseline")
    struct SimulatorBaseline {

        @Test(
            "simulateWork(10μs) actual duration",
            .timed(iterations: 1000, warmup: 100, trackAllocations: false)
        )
        func tenMicroseconds() {
            ThroughputBenchmarks.simulateWork(duration: .microseconds(10))
        }

        @Test(
            "simulateWork(100μs) actual duration",
            .timed(iterations: 100, warmup: 10, trackAllocations: false)
        )
        func hundredMicroseconds() {
            ThroughputBenchmarks.simulateWork(duration: .microseconds(100))
        }

        @Test(
            "simulateWork(1ms) actual duration",
            .timed(iterations: 10, warmup: 2, trackAllocations: false)
        )
        func oneMillisecond() {
            ThroughputBenchmarks.simulateWork(duration: .milliseconds(1))
        }
    }
}

// MARK: - Sequential Throughput

extension ThroughputBenchmarks.Test.Performance {

    @Suite("Sequential Throughput")
    struct Sequential {

        static let fixture = ThreadPoolFixture.shared
        static let operationCount = 1000
        static let workDuration = Duration.microseconds(10)

        @Test(
            "swift-io: 1000 sequential ops (10μs each)",
            .timed(iterations: 3, warmup: 1, trackAllocations: false)
        )
        func swiftIOSequential() async throws {
            let lane = Self.fixture.swiftIOLane
            for _ in 0..<Self.operationCount {
                let result: Result<Int, Never> = try await lane.run(deadline: .none) {
                    ThroughputBenchmarks.simulateWork(duration: Self.workDuration)
                    return 1
                }
                switch result {
                case .success(let value):
                    withExtendedLifetime(value) {}
                }
            }
        }

        @Test(
            "NIOThreadPool: 1000 sequential ops (10μs each)",
            .timed(iterations: 3, warmup: 1, trackAllocations: false)
        )
        func nioSequential() async throws {
            for _ in 0..<Self.operationCount {
                let result = try await Self.fixture.nio.runIfActive {
                    ThroughputBenchmarks.simulateWork(duration: Self.workDuration)
                    return 1
                }
                withExtendedLifetime(result) {}
            }
        }
    }
}

// MARK: - Concurrent Throughput

extension ThroughputBenchmarks.Test.Performance {

    @Suite("Concurrent Throughput")
    struct Concurrent {

        static let fixture = ThreadPoolFixture.shared
        static let operationCount = 1000
        static let workDuration = Duration.microseconds(10)

        @Test(
            "swift-io: 1000 concurrent ops (10μs each)",
            .timed(iterations: 3, warmup: 1, trackAllocations: false)
        )
        func swiftIOConcurrent() async throws {
            let lane = Self.fixture.swiftIOLane
            try await withThrowingTaskGroup(of: Int.self) { group in
                for _ in 0..<Self.operationCount {
                    group.addTask {
                        let result: Result<Int, Never> = try await lane.run(deadline: .none) {
                            ThroughputBenchmarks.simulateWork(duration: Self.workDuration)
                            return 1
                        }
                        switch result {
                        case .success(let value):
                            return value
                        }
                    }
                }
                var total = 0
                for try await value in group {
                    total += value
                }
                withExtendedLifetime(total) {}
            }
        }

        @Test(
            "NIOThreadPool: 1000 concurrent ops (10μs each)",
            .timed(iterations: 3, warmup: 1, trackAllocations: false)
        )
        func nioConcurrent() async throws {
            try await withThrowingTaskGroup(of: Int.self) { group in
                for _ in 0..<Self.operationCount {
                    group.addTask {
                        try await Self.fixture.nio.runIfActive {
                            ThroughputBenchmarks.simulateWork(duration: Self.workDuration)
                            return 1
                        }
                    }
                }
                var total = 0
                for try await value in group {
                    total += value
                }
                withExtendedLifetime(total) {}
            }
        }
    }
}

// MARK: - Heavy Work Throughput

extension ThroughputBenchmarks.Test.Performance {

    @Suite("Heavy Work Throughput")
    struct HeavyWork {

        static let fixture = ThreadPoolFixture.shared
        static let operationCount = 100
        static let workDuration = Duration.milliseconds(1)  // 1ms per operation

        @Test(
            "swift-io: 100 concurrent ops (1ms each)",
            .timed(iterations: 3, warmup: 1, trackAllocations: false)
        )
        func swiftIOHeavy() async throws {
            let lane = Self.fixture.swiftIOLane
            try await withThrowingTaskGroup(of: Int.self) { group in
                for _ in 0..<Self.operationCount {
                    group.addTask {
                        let result: Result<Int, Never> = try await lane.run(deadline: .none) {
                            ThroughputBenchmarks.simulateWork(duration: Self.workDuration)
                            return 1
                        }
                        switch result {
                        case .success(let value):
                            return value
                        }
                    }
                }
                var total = 0
                for try await value in group {
                    total += value
                }
                withExtendedLifetime(total) {}
            }
        }

        @Test(
            "NIOThreadPool: 100 concurrent ops (1ms each)",
            .timed(iterations: 3, warmup: 1, trackAllocations: false)
        )
        func nioHeavy() async throws {
            try await withThrowingTaskGroup(of: Int.self) { group in
                for _ in 0..<Self.operationCount {
                    group.addTask {
                        try await Self.fixture.nio.runIfActive {
                            ThroughputBenchmarks.simulateWork(duration: Self.workDuration)
                            return 1
                        }
                    }
                }
                var total = 0
                for try await value in group {
                    total += value
                }
                withExtendedLifetime(total) {}
            }
        }
    }
}
