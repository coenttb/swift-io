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

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

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
                // Submit more operations than capacity allows
                for _ in 0..<(fillCount + 10) {
                    group.addTask {
                        do {
                            let result: Result<Bool, Never> = try await lane.run(deadline: .none) {
                                // Block until barrier is released - ensures queue fills
                                // before any work completes. Use usleep for actual blocking.
                                usleep(10_000)  // 10ms - long enough to guarantee fill
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

                // Small delay to ensure all tasks are submitted and queued
                try? await Task.sleep(for: .milliseconds(5))

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

// MARK: - Sustained Load (Within Capacity)

extension BackpressureBenchmarks.Test.Performance {

    /// Sustained load tests where offered load stays within configured capacity.
    /// Both swift-io and NIO should complete all operations.
    @Suite("Sustained Load (Within Capacity)")
    struct SustainedWithinCapacity {

        static let threadCount = 4
        static let totalOps = 1000
        static let workMicroseconds = 50

        @Test(
            "swift-io: 1000 ops with sufficient capacity",
            .timed(iterations: 3, warmup: 1, trackAllocations: false)
        )
        func swiftIOWithinCapacity() async throws {
            // Configure capacity to handle all ops without overload
            let options = IO.Blocking.Threads.Options(
                workers: Self.threadCount,
                queueLimit: Self.totalOps,
                acceptanceWaitersLimit: Self.totalOps,
                backpressure: .suspend
            )
            let lane = IO.Blocking.Lane.threads(options)

            try await withThrowingTaskGroup(of: Void.self) { group in
                for _ in 0..<Self.totalOps {
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
            "NIOThreadPool: 1000 ops (unbounded)",
            .timed(iterations: 3, warmup: 1, trackAllocations: false)
        )
        func nioWithinCapacity() async throws {
            let pool = NIOThreadPool(numberOfThreads: Self.threadCount)
            pool.start()

            try await withThrowingTaskGroup(of: Void.self) { group in
                for _ in 0..<Self.totalOps {
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

// MARK: - Sustained Load (Beyond Capacity)

extension BackpressureBenchmarks.Test.Performance {

    /// Tests behavior when offered load exceeds configured capacity.
    /// swift-io should reject excess with .overloaded (bounded memory).
    /// NIO will accept all (unbounded memory growth).
    @Suite("Sustained Load (Beyond Capacity)")
    struct SustainedBeyondCapacity {

        static let threadCount = 4
        static let queueLimit = 64
        static let acceptanceLimit = 128
        static let totalOps = 1000  // Exceeds queueLimit + acceptanceLimit
        static let workMicroseconds = 100

        @Test(
            "swift-io: bounded rejection under overload",
            .timed(iterations: 3, warmup: 1, trackAllocations: true)
        )
        func swiftIOBeyondCapacity() async throws {
            let options = IO.Blocking.Threads.Options(
                workers: Self.threadCount,
                queueLimit: Self.queueLimit,
                acceptanceWaitersLimit: Self.acceptanceLimit,
                backpressure: .throw  // Reject immediately when full
            )
            let lane = IO.Blocking.Lane.threads(options)

            var completed = 0
            var rejected = 0

            await withTaskGroup(of: Bool.self) { group in
                for _ in 0..<Self.totalOps {
                    group.addTask {
                        do {
                            let _: Result<Void, Never> = try await lane.run(deadline: nil) {
                                ThroughputBenchmarks.simulateWork(microseconds: Self.workMicroseconds)
                            }
                            return true
                        } catch {
                            // Expected: .overloaded or .queueFull
                            return false
                        }
                    }
                }

                for await success in group {
                    if success {
                        completed += 1
                    } else {
                        rejected += 1
                    }
                }
            }

            await lane.shutdown()

            // Contract: some should be rejected (bounded queue)
            #expect(rejected > 0, "Expected some ops to be rejected under overload")
            // Contract: memory should stay bounded (tracked by .trackAllocations)
        }

        @Test(
            "NIOThreadPool: unbounded queuing under overload",
            .timed(iterations: 3, warmup: 1, trackAllocations: true)
        )
        func nioBeyondCapacity() async throws {
            let pool = NIOThreadPool(numberOfThreads: Self.threadCount)
            pool.start()

            // NIO accepts all - memory grows unbounded
            try await withThrowingTaskGroup(of: Void.self) { group in
                for _ in 0..<Self.totalOps {
                    group.addTask {
                        try await pool.runIfActive {
                            ThroughputBenchmarks.simulateWork(microseconds: Self.workMicroseconds)
                        }
                    }
                }
                try await group.waitForAll()
            }

            try await pool.shutdownGracefully()
            // Note: All complete, but with higher peak memory
        }
    }
}
