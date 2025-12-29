//
//  BackpressureBenchmarks.swift
//  swift-io
//
//  ## Category: Scenario
//  These are correctness-focused tests where timing is incidental.
//  They validate that backpressure behavior works correctly, not measure
//  the exact latency of rejection or resumption.
//
//  ## What These Benchmarks Validate
//  - Rejection happens when queue is full (failFast strategy)
//  - Suspension and resumption work correctly (wait strategy)
//  - Memory stays bounded under sustained load
//
//  ## Running
//  swift test -c release --filter BackpressureBenchmarks
//
//  ## Note
//  NIOThreadPool doesn't have explicit backpressure - it uses unbounded queues.
//  These benchmarks primarily characterize swift-io behavior and show the
//  difference in backpressure strategies.
//
//  ## Timing Caveat
//  The measured times include setup delays (e.g., gate synchronization, queue
//  filling) that are necessary for correctness but not representative of
//  individual operation costs. For isolated latency measurements, see
//  MicroBenchmarks.swift.
//

import IO
import NIOPosix
import StandardsTestSupport
import Testing

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#elseif canImport(Musl)
    import Musl
#endif

enum BackpressureBenchmarks {
    #TestSuites
}

// MARK: - Blocking Gate (No Foundation)

extension BackpressureBenchmarks {
    /// Two-phase blocking gate using pthread primitives.
    ///
    /// Phase 1: Workers arrive and block, signaling they're ready
    /// Phase 2: Main task waits for N workers to arrive, then opens gate
    ///
    /// This ensures workers are actually blocking before we try to fill the queue.
    final class Gate: @unchecked Sendable {
        private var mutex = pthread_mutex_t()
        private var cond = pthread_cond_t()
        private var arrivedCount: Int = 0
        private var isOpen: Bool = false

        init() {
            pthread_mutex_init(&mutex, nil)
            pthread_cond_init(&cond, nil)
        }

        deinit {
            pthread_cond_destroy(&cond)
            pthread_mutex_destroy(&mutex)
        }

        /// Called by workers: signal arrival and block until gate opens.
        func arriveAndWait() {
            pthread_mutex_lock(&mutex)
            arrivedCount += 1
            pthread_cond_broadcast(&cond)  // Signal that we arrived
            while !isOpen {
                pthread_cond_wait(&cond, &mutex)
            }
            pthread_mutex_unlock(&mutex)
        }

        /// Called by main: wait until N workers have arrived.
        func waitForArrivals(count: Int) {
            pthread_mutex_lock(&mutex)
            while arrivedCount < count {
                pthread_cond_wait(&cond, &mutex)
            }
            pthread_mutex_unlock(&mutex)
        }

        /// Open the gate, releasing all waiters.
        func open() {
            pthread_mutex_lock(&mutex)
            isOpen = true
            pthread_cond_broadcast(&cond)
            pthread_mutex_unlock(&mutex)
        }
    }
}

// MARK: - FailFast Strategy

extension BackpressureBenchmarks.Test.Performance {

    @Suite("FailFast Backpressure")
    struct FailFast {

        static let queueLimit = 16
        static let threadCount = 2

        /// Deterministic test for failFast backpressure.
        ///
        /// ## Design
        /// 1. Submit `threadCount` blocker jobs that will block inside their closures
        /// 2. Wait until workers are actually blocked (two-phase gate)
        /// 3. Submit `queueLimit` jobs to fill the queue
        /// 4. Submit extra jobs that must reject with `.queueFull`
        /// 5. Open gate so accepted work completes and shutdown succeeds
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

            let gate = BackpressureBenchmarks.Gate()
            let extra = 10

            var accepted = 0
            var rejected = 0

            // Phase 1: Submit blocker jobs and wait for workers to be blocked
            let blockerTasks = (0..<Self.threadCount).map { _ in
                Task {
                    do {
                        let result: Result<Bool, Never> = try await lane.run(deadline: .none) {
                            gate.arriveAndWait()  // Signal arrival, then block
                            return true
                        }
                        return result == .success(true)
                    } catch {
                        return false
                    }
                }
            }

            // Wait for all workers to be blocked (they've arrived at the gate)
            gate.waitForArrivals(count: Self.threadCount)

            // Phase 2: Fill the queue
            let queueFillers = (0..<Self.queueLimit).map { _ in
                Task {
                    do {
                        let result: Result<Bool, Never> = try await lane.run(deadline: .none) {
                            ThroughputBenchmarks.simulateWork(microseconds: 100)
                            return true
                        }
                        return result == .success(true)
                    } catch {
                        return false
                    }
                }
            }

            // Give queue fillers time to enqueue
            try? await Task.sleep(nanoseconds: 10_000_000)  // 10ms

            // Phase 3: Submit extra jobs - these should be rejected
            let extraTasks = (0..<extra).map { _ in
                Task {
                    do {
                        let result: Result<Bool, Never> = try await lane.run(deadline: .none) {
                            ThroughputBenchmarks.simulateWork(microseconds: 100)
                            return true
                        }
                        return result == .success(true)
                    } catch {
                        return false
                    }
                }
            }

            // Collect extra task results (these should have immediate rejections)
            for task in extraTasks {
                let success = await task.value
                if success {
                    accepted += 1
                } else {
                    rejected += 1
                }
            }

            // Open gate to let blockers complete
            gate.open()

            // Collect blocker results
            for task in blockerTasks {
                let success = await task.value
                if success { accepted += 1 } else { rejected += 1 }
            }

            // Collect queue filler results
            for task in queueFillers {
                let success = await task.value
                if success { accepted += 1 } else { rejected += 1 }
            }

            await lane.shutdown()

            #expect(
                rejected > 0,
                "Expected some operations to be rejected (accepted=\(accepted), rejected=\(rejected))"
            )
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
