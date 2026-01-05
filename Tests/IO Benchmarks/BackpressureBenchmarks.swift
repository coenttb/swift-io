//
//  BackpressureBenchmarks.swift
//  swift-io
//
//  CAPABILITY BENCHMARKS measuring backpressure behavior.
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
//  These are CAPABILITY benchmarks, not pure performance benchmarks.
//  NIOThreadPool is unbounded by design. Comparing swift-io bounded vs
//  NIO unbounded tests capability differences, not raw performance.
//  For fair performance comparison, use BoundedNIOThreadPool wrapper.
//

import Atomics
import Dimension
import Foundation
import IO
import IO_Test_Support
import NIOPosix
import StandardsTestSupport
import Testing

enum BackpressureBenchmarks {
    #TestSuites
}

// MARK: - Synchronization Primitives for Blocking Tests

/// Latch for synchronizing blocker tasks.
/// Thread-safe for use from blocking worker threads.
final class BlockerLatch: @unchecked Sendable {
    private let started: ManagedAtomic<Int>
    private let released: ManagedAtomic<Bool>
    private let target: Int

    init(count: Int) {
        self.target = count
        self.started = ManagedAtomic(0)
        self.released = ManagedAtomic(false)
    }

    /// Called by each blocker when it starts executing on a worker.
    /// Thread-safe, can be called from blocking context.
    func signalStarted() {
        started.wrappingIncrement(ordering: .releasing)
    }

    /// Returns true when all blockers have signaled.
    var allStarted: Bool {
        started.load(ordering: .acquiring) >= target
    }

    /// Blocks (spins) until released.
    /// Call from blocking worker threads only.
    func blockUntilReleased() {
        while !released.load(ordering: .acquiring) {
            // Spin with brief yield to avoid burning CPU
            Thread.sleep(forTimeInterval: 0.0001)  // 100μs
        }
    }

    /// Releases all waiting blockers.
    func release() {
        released.store(true, ordering: .releasing)
    }
}

// MARK: - Capability: Reject Latency (Scenario)

/// Error thrown when benchmark setup fails.
private enum BenchmarkSetupError: Error {
    case failedToStartWorkers
    case failedToSaturate
    case acceptedWhenExpectedRejection
    case timedOutWhenExpectedRejection
}

extension BackpressureBenchmarks.Test.Performance {

    /// SCENARIO BENCHMARK: Measures full rejection cycle including setup.
    ///
    /// **Note**: This is a SCENARIO benchmark. The .timed region includes:
    /// - Lane/pool creation
    /// - Filling workers and queue (with deterministic barriers)
    /// - Measuring rejection latency
    /// - Cleanup
    ///
    /// The measured time reflects end-to-end scenario cost, NOT pure rejection latency.
    /// For pure rejection latency, see "Pure Rejection Latency" suite.
    ///
    /// swift-io provides bounded queues natively; NIO requires external gating.
    @Suite("Scenario: Full Rejection Cycle")
    struct RejectLatency {

        static let queueLimit = 1      // Minimal queue for fast fill
        static let threadCount = 2
        static let measurementCount = 100

        @Test(
            "swift-io: reject scenario (native backpressure)",
            .timed(iterations: 3, warmup: 1, trackAllocations: false)
        )
        func swiftIORejectLatency() async throws {
            // Use larger acceptance waiter limit to avoid .overloaded during setup
            let options = IO.Blocking.Threads.Options(
                workers: Kernel.Thread.Count(Self.threadCount),
                policy: IO.Backpressure.Policy(
                    strategy: .failFast,
                    laneQueueLimit: Self.queueLimit,
                    laneAcceptanceWaitersLimit: 16  // Room for setup probes
                )
            )
            let lane = IO.Blocking.Lane.threads(options)

            // Latch: workers signal when they start executing
            let latch = BlockerLatch(count: Self.threadCount)

            // Fire-and-forget blocker tasks (no TaskGroup that waits)
            var blockerTasks: [Task<Void, Never>] = []

            // Ensure cleanup runs even on early failure
            defer {
                latch.release()
                for task in blockerTasks {
                    task.cancel()
                }
            }

            // Step 1: Submit blockers to occupy workers
            // Use Task.detached to avoid cancellation from test framework
            for _ in 0..<Self.threadCount {
                let task = Task.detached {
                    _ = try? await lane.run(
                        deadline: IO.Blocking.Deadline.after(.seconds(30))
                    ) {
                        latch.signalStarted()
                        latch.blockUntilReleased()
                    }
                }
                blockerTasks.append(task)
                // Give task time to be scheduled
                try await Task.sleep(for: .milliseconds(10))
            }

            // Step 2: Wait for all workers to be occupied
            var waitCount = 0
            while !latch.allStarted && waitCount < 1_000 {
                try await Task.sleep(for: .milliseconds(1))
                waitCount += 1
            }
            guard latch.allStarted else {
                throw BenchmarkSetupError.failedToStartWorkers
            }

            // Step 3: Fill the queue with more blockers
            // Use Task.detached to avoid cancellation from test framework
            for _ in 0..<Self.queueLimit {
                let task = Task.detached {
                    _ = try? await lane.run(
                        deadline: IO.Blocking.Deadline.after(.seconds(30))
                    ) {
                        // These won't run until workers are freed
                        latch.blockUntilReleased()
                    }
                }
                blockerTasks.append(task)
                // Brief yield to let submission complete
                try await Task.sleep(for: .microseconds(100))
            }

            // Step 4: Probe for .queueFull - this proves saturation
            var saturated = false
            for _ in 0..<500 {
                do {
                    let _: Result<Int, Never> = try await lane.run(
                        deadline: IO.Blocking.Deadline.after(.milliseconds(1))
                    ) { 42 }
                    // Accepted - queue not full yet, yield and retry
                    try await Task.sleep(for: .microseconds(100))
                } catch IO.Blocking.Failure.queueFull {
                    saturated = true
                    break
                } catch IO.Blocking.Failure.deadlineExceeded {
                    // Timed out - keep probing
                    continue
                } catch IO.Blocking.Failure.overloaded {
                    // Acceptance waiter limit hit - keep probing
                    try await Task.sleep(for: .microseconds(100))
                    continue
                }
            }
            guard saturated else {
                throw BenchmarkSetupError.failedToSaturate
            }

            // Step 5: Measure rejection latency
            // Every probe MUST get .queueFull - anything else invalidates the scenario
            var rejections = 0
            for _ in 0..<Self.measurementCount {
                do {
                    let _: Result<Int, Never> = try await lane.run(
                        deadline: IO.Blocking.Deadline.after(.milliseconds(1))
                    ) { 42 }
                    // Accepted when we expected rejection - throw to unwind
                    throw BenchmarkSetupError.acceptedWhenExpectedRejection
                } catch IO.Blocking.Failure.queueFull {
                    rejections += 1
                } catch IO.Blocking.Failure.deadlineExceeded {
                    // Timeout instead of rejection - scenario invalid, throw to unwind
                    throw BenchmarkSetupError.timedOutWhenExpectedRejection
                } catch is BenchmarkSetupError {
                    throw BenchmarkSetupError.acceptedWhenExpectedRejection
                }
            }

            // Release blockers BEFORE shutdown (defer would cause deadlock)
            latch.release()
            for task in blockerTasks {
                task.cancel()
            }

            await lane.shutdown()

            #expect(rejections == Self.measurementCount, "All probes should reject with .queueFull")
        }

        @Test(
            "NIO + external gate: reject scenario (bolted-on backpressure)",
            .timed(iterations: 3, warmup: 1, trackAllocations: false)
        )
        func boundedNIORejectLatency() async throws {
            let pool = NIOThreadPool(numberOfThreads: Self.threadCount)
            pool.start()
            // Limit = threadCount so all permits are held by blockers
            let bounded = BoundedNIOThreadPool(pool: pool, limit: Self.threadCount)

            let latch = BlockerLatch(count: Self.threadCount)

            // Step 1: Fill all permits with blockers through the wrapper
            let blockerTask = Task {
                await withTaskGroup(of: Void.self) { group in
                    for _ in 0..<Self.threadCount {
                        group.addTask {
                            do {
                                _ = try await bounded.runFailFast {
                                    latch.signalStarted()
                                    latch.blockUntilReleased()
                                }
                            } catch {
                                // Blocker failed - unexpected during setup
                            }
                        }
                    }
                    // Don't wait - blockers block until released
                }
            }

            // Ensure cleanup runs even on early failure
            defer {
                latch.release()
                blockerTask.cancel()
            }

            // Step 2: Wait for workers to be occupied
            var waitCount = 0
            while !latch.allStarted && waitCount < 1_000 {
                try await Task.sleep(for: .milliseconds(1))
                waitCount += 1
            }
            guard latch.allStarted else {
                throw BenchmarkSetupError.failedToStartWorkers
            }

            // Step 3: Probe for rejection - proves all permits held
            var saturated = false
            for _ in 0..<500 {
                do {
                    _ = try await bounded.runFailFast { 42 }
                    // Accepted - not saturated yet
                    try await Task.sleep(for: .microseconds(100))
                } catch is BoundedPoolOverloadError {
                    saturated = true
                    break
                }
            }
            guard saturated else {
                throw BenchmarkSetupError.failedToSaturate
            }

            // Step 4: Measure rejection latency
            var rejections = 0
            for _ in 0..<Self.measurementCount {
                do {
                    _ = try await bounded.runFailFast { 42 }
                    throw BenchmarkSetupError.acceptedWhenExpectedRejection
                } catch is BoundedPoolOverloadError {
                    rejections += 1
                } catch is BenchmarkSetupError {
                    throw BenchmarkSetupError.acceptedWhenExpectedRejection
                }
            }

            // Release blockers BEFORE shutdown (defer would cause deadlock)
            latch.release()
            blockerTask.cancel()

            try await pool.shutdownGracefully()

            #expect(rejections == Self.measurementCount, "All probes should reject")
        }
    }
}

// MARK: - Pure Rejection Latency

extension BackpressureBenchmarks.Test.Performance {

    /// PURE LATENCY BENCHMARK: Measures only the rejection path overhead.
    ///
    /// **Key difference from "Scenario: Full Rejection Cycle"**:
    /// - Setup (saturation) happens ONCE in a shared fixture
    /// - Only the rejection call is timed
    /// - Uses `runImmediate` (deadline: .now) for minimal wait overhead
    ///
    /// This measures the actual cost of checking queue-full and returning `.queueFull`,
    /// not the scenario setup overhead.
    @Suite("Pure Rejection Latency")
    struct PureRejection {

        /// Shared fixture that maintains a saturated lane across iterations.
        /// Setup happens once; measurements use the pre-saturated state.
        actor SaturatedLaneFixture {
            private var lane: IO.Blocking.Lane?
            private var blockerTasks: [Task<Void, Never>] = []
            private var latch: BlockerLatch?
            private var isSetUp = false

            static let shared = SaturatedLaneFixture()

            func setUp() async throws {
                guard !isSetUp else { return }

                let threadCount = 2
                let queueLimit = 1

                let options = IO.Blocking.Threads.Options(
                    workers: Kernel.Thread.Count(threadCount),
                    policy: IO.Backpressure.Policy(
                        strategy: .failFast,
                        laneQueueLimit: queueLimit,
                        laneAcceptanceWaitersLimit: 16
                    )
                )
                lane = IO.Blocking.Lane.threads(options)

                let newLatch = BlockerLatch(count: threadCount)
                latch = newLatch

                // Saturate workers
                for _ in 0..<threadCount {
                    let task = Task.detached { [lane] in
                        _ = try? await lane?.run(
                            deadline: IO.Blocking.Deadline.after(.seconds(300))
                        ) {
                            newLatch.signalStarted()
                            newLatch.blockUntilReleased()
                        }
                    }
                    blockerTasks.append(task)
                }

                // Wait for workers to be occupied
                var waitCount = 0
                while !newLatch.allStarted && waitCount < 1_000 {
                    try await Task.sleep(for: .milliseconds(1))
                    waitCount += 1
                }

                // Fill queue
                for _ in 0..<queueLimit {
                    let task = Task.detached { [lane] in
                        _ = try? await lane?.run(
                            deadline: IO.Blocking.Deadline.after(.seconds(300))
                        ) {
                            newLatch.blockUntilReleased()
                        }
                    }
                    blockerTasks.append(task)
                    try await Task.sleep(for: .microseconds(100))
                }

                // Verify saturated
                var saturated = false
                for _ in 0..<100 {
                    do {
                        let _: Int = try await lane!.runImmediate { 42 }
                        try await Task.sleep(for: .microseconds(100))
                    } catch IO.Blocking.Failure.queueFull {
                        saturated = true
                        break
                    } catch IO.Blocking.Failure.deadlineExceeded {
                        saturated = true  // Also indicates full
                        break
                    } catch {
                        break
                    }
                }

                guard saturated else {
                    throw BenchmarkSetupError.failedToSaturate
                }

                isSetUp = true
            }

            func tearDown() async {
                latch?.release()
                for task in blockerTasks {
                    task.cancel()
                }
                await lane?.shutdown()
                blockerTasks = []
                lane = nil
                latch = nil
                isSetUp = false
            }

            var activeLane: IO.Blocking.Lane {
                lane!
            }
        }

        static let measurementCount = 1000

        @Test(
            "swift-io: pure .queueFull rejection latency",
            .timed(iterations: 5, warmup: 1, trackAllocations: false)
        )
        func pureRejectionLatency() async throws {
            let fixture = SaturatedLaneFixture.shared
            try await fixture.setUp()

            let lane = await fixture.activeLane

            // Pure measurement: just the rejection calls
            var rejections = 0
            for _ in 0..<Self.measurementCount {
                do {
                    let _: Int = try await lane.runImmediate { 42 }
                } catch IO.Blocking.Failure.queueFull {
                    rejections += 1
                } catch IO.Blocking.Failure.deadlineExceeded {
                    rejections += 1  // Also counts as rejection
                } catch {
                    // Unexpected
                }
            }

            #expect(rejections == Self.measurementCount, "All should reject")
        }

        @Test(
            "NIO + gate: pure rejection latency",
            .timed(iterations: 5, warmup: 1, trackAllocations: false)
        )
        func nioPureRejectionLatency() async throws {
            // NIO fixture is lightweight - semaphore rejection is fast
            let pool = NIOThreadPool(numberOfThreads: 2)
            pool.start()
            let bounded = BoundedNIOThreadPool(pool: pool, limit: 2)

            let latch = BlockerLatch(count: 2)

            // Saturate
            let blockerTask = Task {
                await withTaskGroup(of: Void.self) { group in
                    for _ in 0..<2 {
                        group.addTask {
                            _ = try? await bounded.runFailFast {
                                latch.signalStarted()
                                latch.blockUntilReleased()
                            }
                        }
                    }
                }
            }

            var waitCount = 0
            while !latch.allStarted && waitCount < 1_000 {
                try await Task.sleep(for: .milliseconds(1))
                waitCount += 1
            }

            // Pure measurement
            var rejections = 0
            for _ in 0..<Self.measurementCount {
                do {
                    _ = try await bounded.runFailFast { 42 }
                } catch is BoundedPoolOverloadError {
                    rejections += 1
                } catch {
                    // Unexpected
                }
            }

            latch.release()
            blockerTask.cancel()
            try await pool.shutdownGracefully()

            #expect(rejections == Self.measurementCount, "All should reject")
        }
    }
}

// MARK: - Capability: Wait/Suspend Strategy

extension BackpressureBenchmarks.Test.Performance {

    /// CAPABILITY BENCHMARK: Measures suspend-until-capacity behavior.
    /// swift-io provides this natively via .wait strategy.
    @Suite("Capability: Wait Backpressure")
    struct Wait {

        static let queueLimit = 16
        static let threadCount = 2

        @Test(
            "swift-io: suspend until capacity (native)",
            .timed(iterations: 5, warmup: 1, trackAllocations: false)
        )
        func suspendUntilCapacity() async throws {
            let options = IO.Blocking.Threads.Options(
                workers: Kernel.Thread.Count(Self.threadCount),
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
                            ThroughputBenchmarks.simulateWork(duration: .microseconds(100))
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
        static let workDuration = Duration.microseconds(50)

        @Test(
            "swift-io: 1000 ops with sufficient capacity",
            .timed(iterations: 3, warmup: 1, trackAllocations: false)
        )
        func swiftIOWithinCapacity() async throws {
            // Configure capacity to handle all ops without overload
            let options = IO.Blocking.Threads.Options(
                workers: Kernel.Thread.Count(Self.threadCount),
                queueLimit: Self.totalOps,
                acceptanceWaitersLimit: Self.totalOps,
                backpressure: .suspend
            )
            let lane = IO.Blocking.Lane.threads(options)

            try await withThrowingTaskGroup(of: Void.self) { group in
                for _ in 0..<Self.totalOps {
                    group.addTask {
                        let result: Result<Void, Never> = try await lane.run(deadline: .none) {
                            ThroughputBenchmarks.simulateWork(duration: Self.workDuration)
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
                            ThroughputBenchmarks.simulateWork(duration: Self.workDuration)
                        }
                    }
                }
                try await group.waitForAll()
            }

            try await pool.shutdownGracefully()
        }
    }
}

// MARK: - Capability: Memory Under Overload

extension BackpressureBenchmarks.Test.Performance {

    /// CAPABILITY BENCHMARK: Demonstrates bounded vs unbounded memory behavior.
    /// swift-io should reject excess (bounded memory).
    /// NIO will accept all (unbounded memory growth).
    @Suite("Capability: Memory Under Overload")
    struct SustainedBeyondCapacity {

        static let threadCount = 4
        static let queueLimit = 64
        static let acceptanceLimit = 128
        static let totalOps = 1000  // Exceeds queueLimit + acceptanceLimit
        static let workDuration = Duration.microseconds(100)

        @Test(
            "swift-io: bounded rejection under overload",
            .timed(iterations: 3, warmup: 1, trackAllocations: true)
        )
        func swiftIOBeyondCapacity() async throws {
            let options = IO.Blocking.Threads.Options(
                workers: Kernel.Thread.Count(Self.threadCount),
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
                                ThroughputBenchmarks.simulateWork(duration: Self.workDuration)
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
                            ThroughputBenchmarks.simulateWork(duration: Self.workDuration)
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
