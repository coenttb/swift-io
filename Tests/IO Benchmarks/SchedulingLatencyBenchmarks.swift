//
//  SchedulingLatencyBenchmarks.swift
//  swift-io
//
//  ## Category: Micro
//  These benchmarks isolate scheduling latency in tight loops.
//  They measure individual operation overhead without confounding factors.
//
//  ## What These Benchmarks Measure
//  - Pool actor method call latency (non-blocking actor work)
//  - Scheduling jitter with dedicated executor threads
//  - Round-trip time for actor state transitions
//
//  ## Key Metrics
//  Focus on P50/P99/P999 latency to measure scheduling predictability.
//  Executor pinning should reduce jitter (tighter distribution).
//
//  ## Running
//  swift test -c release --filter SchedulingLatencyBenchmarks
//

import IO
import StandardsTestSupport
import Testing

enum SchedulingLatencyBenchmarks {
    #TestSuites
}

// MARK: - Pool Actor Scheduling

extension SchedulingLatencyBenchmarks.Test.Performance {

    @Suite("Pool Actor Scheduling")
    struct PoolActorScheduling {

        /// Minimal fixture: Pool with inline lane (no blocking I/O)
        /// This isolates actor scheduling overhead from lane dispatch.
        static let pool: IO.Executor.Pool<Int> = {
            IO.Executor.Pool(lane: .inline)
        }()

        @Test(
            "swift-io: pool method round-trip latency",
            .timed(iterations: 2000, warmup: 200, trackAllocations: false)
        )
        func poolMethodLatency() async throws {
            // Measures: async call → actor hop → return
            // The pool runs on a dedicated executor thread, so this
            // should have low jitter compared to default executor.
            // Uses a cheap actor-isolated method (isValid with fake ID).
            let valid = await Self.pool.isValid(.init(raw: 0, scope: 0))
            withExtendedLifetime(valid) {}
        }

        @Test(
            "swift-io: pool register/destroy cycle latency",
            .timed(iterations: 1000, warmup: 100, trackAllocations: false)
        )
        func poolRegisterDestroyLatency() async throws {
            // Measures complete lifecycle: register → destroy
            // Both are actor-isolated operations on the pinned executor.
            let id = try await Self.pool.register(42)
            try await Self.pool.destroy(id)
        }
    }
}

// MARK: - Executor Thread Scheduling

extension SchedulingLatencyBenchmarks.Test.Performance {

    @Suite("Executor Thread Scheduling")
    struct ExecutorThreadScheduling {

        /// Shared executor threads for benchmarking.
        static let executorPool = IO.Executor.Threads(.init(count: 4))

        @Test(
            "swift-io: task on executor thread latency",
            .timed(iterations: 2000, warmup: 200, trackAllocations: false)
        )
        func taskExecutorLatency() async {
            // Measures: Task creation → executor hop → completion
            let executor = Self.executorPool.next()
            let result = await Task(executorPreference: executor) {
                42
            }.value
            withExtendedLifetime(result) {}
        }

        @Test(
            "swift-io: round-robin executor distribution",
            .timed(iterations: 2000, warmup: 200, trackAllocations: false)
        )
        func roundRobinLatency() async {
            // Measures scheduling with round-robin distribution
            // Each iteration goes to a different executor thread.
            let executor = Self.executorPool.next()
            let result = await Task(executorPreference: executor) {
                42
            }.value
            withExtendedLifetime(result) {}
        }
    }
}

// MARK: - Comparative Scheduling

extension SchedulingLatencyBenchmarks.Test.Performance {

    @Suite("Comparative Scheduling")
    struct ComparativeScheduling {

        static let pinnedPool: IO.Executor.Pool<Int> = {
            IO.Executor.Pool(lane: .inline)
        }()

        @Test(
            "swift-io: pinned pool method latency",
            .timed(iterations: 1000, warmup: 100, trackAllocations: false)
        )
        func pinnedPoolLatency() async throws {
            // Pool on dedicated executor thread
            let valid = await Self.pinnedPool.isValid(.init(raw: 0, scope: 0))
            withExtendedLifetime(valid) {}
        }

        @Test(
            "baseline: default executor task latency",
            .timed(iterations: 1000, warmup: 100, trackAllocations: false)
        )
        func defaultExecutorLatency() async {
            // Task on default (global) executor for comparison
            let result = await Task { 42 }.value
            withExtendedLifetime(result) {}
        }
    }
}
