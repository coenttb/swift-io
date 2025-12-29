//
//  CancellationBenchmarks.swift
//  swift-io
//
//  Benchmarks measuring cancellation overhead and semantics.
//
//  ## What These Benchmarks Measure
//  - Cost of cancellation before acceptance
//  - Cost of cancellation after acceptance
//  - Cleanup overhead when operations are cancelled
//
//  ## Running
//  swift test -c release --filter CancellationBenchmarks
//

import IO
import NIOPosix
import StandardsTestSupport
import Testing

enum CancellationBenchmarks {
    #TestSuites
}

// MARK: - Pre-Acceptance Cancellation

extension CancellationBenchmarks.Test.Performance {

    @Suite("Pre-Acceptance Cancellation")
    struct PreAcceptance {

        static let threadCount = 2
        static let queueLimit = 8

        @Test(
            "swift-io: cancel before acceptance",
            .timed(iterations: 100, warmup: 20, trackAllocations: false)
        )
        func swiftIOPreAcceptance() async throws {
            // Tiny queue to force waiting
            let options = IO.Blocking.Threads.Options(
                workers: Self.threadCount,
                policy: IO.Backpressure.Policy(
                    strategy: .wait,
                    laneQueueLimit: Self.queueLimit
                )
            )
            let lane = IO.Blocking.Lane.threads(options)

            // Fill queue with blocking operations
            let blockers = Task {
                try await withThrowingTaskGroup(of: Void.self) { group in
                    for _ in 0..<(Self.queueLimit + Self.threadCount) {
                        group.addTask {
                            let result: Result<Void, Never> = try await lane.run(deadline: .none) {
                                ThroughputBenchmarks.simulateWork(microseconds: 10000)
                            }
                            _ = result
                        }
                    }
                    try await group.waitForAll()
                }
            }

            // Small delay to let blockers fill the queue
            try await Task.sleep(for: .milliseconds(10))

            // Now submit and immediately cancel
            let cancelledTask = Task {
                do {
                    let result: Result<Int, Never> = try await lane.run(deadline: .none) {
                        return 42
                    }
                    switch result {
                    case .success(let value):
                        return value
                    }
                } catch {
                    return -1  // Cancelled
                }
            }

            // Cancel immediately
            cancelledTask.cancel()

            // Wait for cancellation to propagate
            let result = await cancelledTask.value
            #expect(result == -1)

            // Cancel blockers to clean up
            blockers.cancel()
            _ = await blockers.result

            await lane.shutdown()
        }
    }
}

// MARK: - Post-Acceptance Cancellation

extension CancellationBenchmarks.Test.Performance {

    @Suite("Post-Acceptance Cancellation")
    struct PostAcceptance {

        static let fixture = ThreadPoolFixture.shared

        @Test(
            "swift-io: cancel after acceptance",
            .timed(iterations: 50, warmup: 10, trackAllocations: false)
        )
        func swiftIOPostAcceptance() async throws {
            let lane = Self.fixture.swiftIOLane

            let task = Task {
                do {
                    let result: Result<Int, Never> = try await lane.run(deadline: .none) {
                        // Long-running work that will be "cancelled"
                        ThroughputBenchmarks.simulateWork(microseconds: 5000)
                        return 42
                    }
                    switch result {
                    case .success(let value):
                        return value
                    }
                } catch {
                    return -1
                }
            }

            // Small delay to ensure acceptance
            try await Task.sleep(for: .microseconds(100))

            // Cancel after acceptance - operation should still complete per swift-io semantics
            task.cancel()

            // Wait for completion
            _ = await task.value
            // Note: swift-io guarantees execution once accepted, so result may be 42 or -1
            // depending on timing
        }
    }
}

// MARK: - Batch Cancellation

extension CancellationBenchmarks.Test.Performance {

    @Suite("Batch Cancellation")
    struct Batch {

        static let threadCount = 4
        static let taskCount = 100

        @Test(
            "swift-io: cancel 100 tasks",
            .timed(iterations: 10, warmup: 2, trackAllocations: false)
        )
        func swiftIOBatch() async throws {
            let lane = IO.Blocking.Lane.threads(.init(workers: Self.threadCount))

            let parentTask = Task {
                try await withThrowingTaskGroup(of: Int.self) { group in
                    for i in 0..<Self.taskCount {
                        group.addTask {
                            let result: Result<Int, Never> = try await lane.run(deadline: .none) {
                                ThroughputBenchmarks.simulateWork(microseconds: 1000)
                                return i
                            }
                            switch result {
                            case .success(let value):
                                return value
                            }
                        }
                    }
                    var sum = 0
                    for try await value in group {
                        sum += value
                    }
                    return sum
                }
            }

            // Let some tasks start
            try await Task.sleep(for: .milliseconds(5))

            // Cancel entire group
            parentTask.cancel()

            _ = await parentTask.result

            await lane.shutdown()
        }

        @Test(
            "NIOThreadPool: cancel 100 tasks",
            .timed(iterations: 10, warmup: 2, trackAllocations: false)
        )
        func nioBatch() async throws {
            let pool = NIOThreadPool(numberOfThreads: Self.threadCount)
            pool.start()

            let parentTask = Task {
                try await withThrowingTaskGroup(of: Int.self) { group in
                    for i in 0..<Self.taskCount {
                        group.addTask {
                            try await pool.runIfActive {
                                ThroughputBenchmarks.simulateWork(microseconds: 1000)
                                return i
                            }
                        }
                    }
                    var sum = 0
                    for try await value in group {
                        sum += value
                    }
                    return sum
                }
            }

            // Let some tasks start
            try await Task.sleep(for: .milliseconds(5))

            // Cancel entire group
            parentTask.cancel()

            _ = await parentTask.result

            try await pool.shutdownGracefully()
        }
    }
}
