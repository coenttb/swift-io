//
//  OverheadBenchmarks.swift
//  swift-io
//
//  ## Category: Micro
//  These benchmarks isolate framework overhead with trivial operations.
//  They measure individual operation costs without work interference.
//
//  ## What These Benchmarks Measure
//  - Pure dispatch overhead (no actual blocking work)
//  - Lane/pool machinery cost per operation
//  - Typed error handling overhead
//
//  ## Running
//  swift test -c release --filter OverheadBenchmarks
//

import IO
import NIOPosix
import StandardsTestSupport
import Testing

enum OverheadBenchmarks {
    #TestSuites
}

// MARK: - Inline Overhead (No Thread Dispatch)

extension OverheadBenchmarks.Test.Performance {

    @Suite("Inline Overhead")
    struct Inline {

        @Test(
            "swift-io: inline lane overhead",
            .timed(iterations: 1000, warmup: 100, trackAllocations: false)
        )
        func swiftIOInline() async throws {
            let lane = IO.Blocking.Lane.inline
            let result: Result<Int, Never> = try await lane.run(deadline: .none) { 42 }
            switch result {
            case .success(let value):
                withExtendedLifetime(value) {}
            }
        }
    }
}

// MARK: - Thread Dispatch Overhead

extension OverheadBenchmarks.Test.Performance {

    @Suite("Thread Dispatch Overhead")
    struct ThreadDispatch {

        static let fixture = ThreadPoolFixture.shared

        @Test(
            "swift-io: thread dispatch overhead",
            .timed(iterations: 500, warmup: 50, trackAllocations: false)
        )
        func swiftIOThreads() async throws {
            let lane = Self.fixture.swiftIOLane
            let result: Result<Int, Never> = try await lane.run(deadline: .none) { 42 }
            switch result {
            case .success(let value):
                withExtendedLifetime(value) {}
            }
        }

        @Test(
            "NIOThreadPool: thread dispatch overhead",
            .timed(iterations: 500, warmup: 50, trackAllocations: false)
        )
        func nioThreadPool() async throws {
            let result = try await Self.fixture.nio.runIfActive { 42 }
            withExtendedLifetime(result) {}
        }
    }
}

// MARK: - Typed Error Overhead

extension OverheadBenchmarks.Test.Performance {

    @Suite("Typed Error Overhead")
    struct TypedError {

        struct BenchmarkError: Error, Sendable {}

        static let fixture = ThreadPoolFixture.shared

        @Test(
            "swift-io: success path with typed error",
            .timed(iterations: 500, warmup: 50, trackAllocations: false)
        )
        func swiftIOSuccess() async throws {
            let lane = Self.fixture.swiftIOLane
            let result: Result<Int, BenchmarkError> = try await lane.run(deadline: .none) { () throws(BenchmarkError) -> Int in
                42
            }
            switch result {
            case .success(let value):
                withExtendedLifetime(value) {}
            case .failure:
                break
            }
        }

        @Test(
            "swift-io: failure path with typed error",
            .timed(iterations: 500, warmup: 50, trackAllocations: false)
        )
        func swiftIOFailure() async throws {
            let lane = Self.fixture.swiftIOLane
            let result: Result<Int, BenchmarkError> = try await lane.run(deadline: .none) { () throws(BenchmarkError) -> Int in
                throw BenchmarkError()
            }
            switch result {
            case .success:
                break
            case .failure(let error):
                withExtendedLifetime(error) {}
            }
        }

        @Test(
            "NIOThreadPool: success path",
            .timed(iterations: 500, warmup: 50, trackAllocations: false)
        )
        func nioSuccess() async throws {
            let result = try await Self.fixture.nio.runIfActive { 42 }
            withExtendedLifetime(result) {}
        }

        @Test(
            "NIOThreadPool: failure path",
            .timed(iterations: 500, warmup: 50, trackAllocations: false)
        )
        func nioFailure() async throws {
            do {
                _ = try await Self.fixture.nio.runIfActive { throw BenchmarkError() }
            } catch {
                withExtendedLifetime(error) {}
            }
        }
    }
}
