//
//  MemoryBenchmarks.swift
//  swift-io
//
//  Benchmarks measuring memory allocation patterns.
//
//  ## What These Benchmarks Measure
//  - Per-operation allocation overhead
//  - Boxing/unboxing cost
//  - Memory pressure under sustained load
//
//  ## Running
//  swift test -c release --filter MemoryBenchmarks
//
//  ## Note
//  Set trackAllocations: true to see allocation counts.
//  These benchmarks focus on relative allocation behavior.
//

import IO
import NIOPosix
import StandardsTestSupport
import Testing

enum MemoryBenchmarks {
    #TestSuites
}

// MARK: - Per-Operation Allocations

extension MemoryBenchmarks.Test.Performance {

    @Suite("Per-Operation Allocations")
    struct PerOperation {

        static let fixture = ThreadPoolFixture.shared
        static let operationCount = 100

        @Test(
            "swift-io: allocations per operation",
            .timed(iterations: 10, warmup: 2, trackAllocations: true)
        )
        func swiftIOAllocations() async throws {
            let lane = Self.fixture.swiftIOLane
            for _ in 0..<Self.operationCount {
                let result: Result<Int, Never> = try await lane.run(deadline: .none) { 42 }
                switch result {
                case .success(let value):
                    withExtendedLifetime(value) {}
                }
            }
        }

        @Test(
            "NIOThreadPool: allocations per operation",
            .timed(iterations: 10, warmup: 2, trackAllocations: true)
        )
        func nioAllocations() async throws {
            for _ in 0..<Self.operationCount {
                let result = try await Self.fixture.nio.runIfActive { 42 }
                withExtendedLifetime(result) {}
            }
        }
    }
}

// MARK: - Large Value Boxing

extension MemoryBenchmarks.Test.Performance {

    @Suite("Large Value Boxing")
    struct LargeValue {

        static let fixture = ThreadPoolFixture.shared

        struct LargeResult: Sendable {
            var data: [UInt8]
            init(size: Int) {
                self.data = [UInt8](repeating: 0xAB, count: size)
            }
        }

        static let resultSize = 1024  // 1KB result

        @Test(
            "swift-io: 1KB result boxing",
            .timed(iterations: 100, warmup: 10, trackAllocations: true)
        )
        func swiftIOLargeResult() async throws {
            let lane = Self.fixture.swiftIOLane
            let result: Result<LargeResult, Never> = try await lane.run(deadline: .none) {
                LargeResult(size: Self.resultSize)
            }
            switch result {
            case .success(let value):
                withExtendedLifetime(value.data.count) {}
            }
        }

        @Test(
            "NIOThreadPool: 1KB result boxing",
            .timed(iterations: 100, warmup: 10, trackAllocations: true)
        )
        func nioLargeResult() async throws {
            let result = try await Self.fixture.nio.runIfActive {
                LargeResult(size: Self.resultSize)
            }
            withExtendedLifetime(result.data.count) {}
        }
    }
}

// MARK: - Error Boxing

extension MemoryBenchmarks.Test.Performance {

    @Suite("Error Boxing")
    struct ErrorBoxing {

        static let fixture = ThreadPoolFixture.shared

        struct DetailedError: Error, Sendable {
            var code: Int
            var message: String
            var context: [String: String]

            static func sample() -> DetailedError {
                DetailedError(
                    code: 42,
                    message: "Something went wrong with the operation",
                    context: ["key1": "value1", "key2": "value2"]
                )
            }
        }

        @Test(
            "swift-io: error boxing",
            .timed(iterations: 100, warmup: 10, trackAllocations: true)
        )
        func swiftIOErrorBoxing() async throws {
            let lane = Self.fixture.swiftIOLane
            let result: Result<Int, DetailedError> = try await lane.run(deadline: .none) { () throws(DetailedError) -> Int in
                throw DetailedError.sample()
            }
            switch result {
            case .success:
                break
            case .failure(let error):
                withExtendedLifetime(error) {}
            }
        }

        @Test(
            "NIOThreadPool: error boxing",
            .timed(iterations: 100, warmup: 10, trackAllocations: true)
        )
        func nioErrorBoxing() async throws {
            do {
                _ = try await Self.fixture.nio.runIfActive {
                    throw DetailedError.sample()
                }
            } catch {
                withExtendedLifetime(error) {}
            }
        }
    }
}

// MARK: - Sustained Memory Pressure

extension MemoryBenchmarks.Test.Performance {

    @Suite("Sustained Memory Pressure")
    struct Sustained {

        static let threadCount = 4
        static let operationCount = 1000

        @Test(
            "swift-io: 1000 ops memory profile",
            .timed(iterations: 3, warmup: 1, trackAllocations: true)
        )
        func swiftIOSustained() async throws {
            let lane = IO.Blocking.Lane.threads(.init(workers: Self.threadCount))

            try await withThrowingTaskGroup(of: [UInt8].self) { group in
                for _ in 0..<Self.operationCount {
                    group.addTask {
                        let result: Result<[UInt8], Never> = try await lane.run(deadline: .none) {
                            [UInt8](repeating: 0xCD, count: 256)
                        }
                        switch result {
                        case .success(let value):
                            return value
                        }
                    }
                }
                var totalBytes = 0
                for try await data in group {
                    totalBytes += data.count
                }
                withExtendedLifetime(totalBytes) {}
            }

            await lane.shutdown()
        }

        @Test(
            "NIOThreadPool: 1000 ops memory profile",
            .timed(iterations: 3, warmup: 1, trackAllocations: true)
        )
        func nioSustained() async throws {
            let pool = NIOThreadPool(numberOfThreads: Self.threadCount)
            pool.start()

            try await withThrowingTaskGroup(of: [UInt8].self) { group in
                for _ in 0..<Self.operationCount {
                    group.addTask {
                        try await pool.runIfActive {
                            [UInt8](repeating: 0xCD, count: 256)
                        }
                    }
                }
                var totalBytes = 0
                for try await data in group {
                    totalBytes += data.count
                }
                withExtendedLifetime(totalBytes) {}
            }

            try await pool.shutdownGracefully()
        }
    }
}
