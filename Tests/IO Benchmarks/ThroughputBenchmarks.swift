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
    /// Simulates blocking work by spinning for approximately the given duration.
    /// Uses spinning instead of sleep for more consistent timing.
    @inline(never)
    static func simulateWork(microseconds: Int) {
        let iterations = microseconds * 100  // Approximate calibration
        var sum = 0
        for i in 0..<iterations {
            sum &+= i
        }
        withExtendedLifetime(sum) {}
    }
}

// MARK: - Sequential Throughput

extension ThroughputBenchmarks.Test.Performance {

    @Suite("Sequential Throughput")
    struct Sequential {

        static let fixture = ThreadPoolFixture.shared
        static let operationCount = 1000
        static let workMicroseconds = 10

        @Test(
            "swift-io: 1000 sequential ops (10μs each)",
            .timed(iterations: 3, warmup: 1, trackAllocations: false)
        )
        func swiftIOSequential() async throws {
            let lane = Self.fixture.swiftIOLane
            for _ in 0..<Self.operationCount {
                let result: Result<Int, Never> = try await lane.run(deadline: .none) {
                    ThroughputBenchmarks.simulateWork(microseconds: Self.workMicroseconds)
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
                    ThroughputBenchmarks.simulateWork(microseconds: Self.workMicroseconds)
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
        static let workMicroseconds = 10

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
                            ThroughputBenchmarks.simulateWork(microseconds: Self.workMicroseconds)
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
                            ThroughputBenchmarks.simulateWork(microseconds: Self.workMicroseconds)
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
        static let workMicroseconds = 1000  // 1ms per operation

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
                            ThroughputBenchmarks.simulateWork(microseconds: Self.workMicroseconds)
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
                            ThroughputBenchmarks.simulateWork(microseconds: Self.workMicroseconds)
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
