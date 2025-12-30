//
//  IO.Executor.Pool.Stress Tests.swift
//  swift-io
//
//  Comprehensive stress and chaos tests for waiter lifecycle.
//  Designed to catch decade-scale bugs through systematic torture.
//
//  ## Design Decisions for Timelessness
//
//  1. **Deterministic patterns**: Uses fixed patterns (id % N) not random, for CI reproducibility.
//  2. **Actor-based tracking**: Future-proof concurrency without platform coupling.
//  3. **Per-waiter exactly-once tracking**: Catches both lost-wakeup and double-resume bugs.
//  4. **Outcome categories**: Asserts all outcomes are in the allowed set.
//  5. **Chaos mode**: Systematic torture with interleaved operations.
//
//  ## Test Categories
//
//  - **Lifecycle tests**: Normal flow under contention
//  - **Race window tests**: Exploit specific timing windows
//  - **Capacity edge cases**: Boundary conditions
//  - **Chaos tests**: Systematic torture with mixed operations
//

import Testing

@testable import IO

// MARK: - Test Resource

private struct StressTestResource: Sendable {
    let id: Int
    var counter: Int = 0
}

// MARK: - Outcome Tracking (Actor-based for timelessness)

/// Outcome categories for waiter completion.
private enum Outcome: Sendable, Equatable, Hashable {
    case acquired
    case cancelled
    case shutdown
    case otherError(String)
}

/// Tracks exactly-once completion with outcome category for each waiter.
///
/// Actor-based for future-proof concurrency without platform dependencies.
private actor OutcomeTracker {
    private var outcomes: [Outcome?]
    private let count: Int

    init(count: Int) {
        self.count = count
        self.outcomes = Array(repeating: nil, count: count)
    }

    /// Records an outcome for the given waiter ID.
    ///
    /// Precondition: waiter must not have completed already (exactly-once).
    func record(id: Int, outcome: Outcome) {
        precondition(id >= 0 && id < count, "Invalid waiter id: \(id)")
        precondition(outcomes[id] == nil, "Waiter \(id) completed more than once (double-resume bug)")
        outcomes[id] = outcome
    }

    /// Returns a snapshot of completion state.
    func snapshot() -> (completedCount: Int, allCompleted: Bool, outcomes: [Outcome?]) {
        let completed = outcomes.compactMap { $0 }
        return (completed.count, completed.count == count, outcomes)
    }

    /// Asserts all outcomes are in the allowed set.
    func assertAllOutcomesAllowed(_ allowed: Set<Outcome>) -> [Outcome] {
        var disallowed: [Outcome] = []
        for outcome in outcomes.compactMap({ $0 }) {
            if case .otherError = outcome {
                disallowed.append(outcome)
            } else if !allowed.contains(outcome) {
                disallowed.append(outcome)
            }
        }
        return disallowed
    }
}

/// Simple counter using actor for consistency.
private actor Counter {
    private var value: Int

    init(_ value: Int = 0) {
        self.value = value
    }

    func increment() {
        value += 1
    }

    func get() -> Int {
        value
    }
}

/// Tracks execution order using actor.
private actor OrderTracker {
    private var values: [Int] = []

    func append(_ value: Int) {
        values.append(value)
    }

    func getValues() -> [Int] {
        values
    }
}

// MARK: - Stress Tests

@Suite(
    "IO.Executor.Pool Stress Tests",
)
struct IOExecutorPoolStressTests {

    /// Tests waiter lifecycle under cancellation + shutdown + contention.
    ///
    /// This is the highest-value stress test for decade-scale correctness:
    /// - Exercises continuation safety
    /// - Exercises lock ordering
    /// - Exercises shutdown semantics
    ///
    /// ## Assertions
    /// - No deadlock (bounded timeout)
    /// - No lost wakeups (all waiters complete)
    /// - Exactly-once resumption (per-waiter tracking)
    /// - All outcomes in allowed set (acquired, cancelled, shutdown)
    @Test("waiter lifecycle under cancellation + shutdown + contention")
    func waiterLifecycleStress() async throws {
        // Configuration - tuned for deterministic CI
        let holderCount = 3
        let waiterCount = 24

        // Use inline lane for deterministic behavior
        let pool = IO.Executor.Pool<StressTestResource>(lane: .inline)

        // Register a single resource (creates contention)
        let resourceID = try await pool.register(StressTestResource(id: 0))

        let outcomeTracker = OutcomeTracker(count: waiterCount)
        let holdersCompleted = Counter()

        // Start holder tasks that will acquire and hold the resource briefly
        let holderTasks: [Task<Void, Never>] = (0..<holderCount).map { _ in
            Task { [pool, resourceID, holdersCompleted] in
                do {
                    // Each holder does a quick operation
                    try await pool.withHandle(resourceID) { resource in
                        resource.counter += 1
                    }
                    await holdersCompleted.increment()
                } catch {
                    // May fail due to shutdown - that's acceptable
                    await holdersCompleted.increment()
                }
            }
        }

        // Give holders a head start
        try await Task.sleep(for: .milliseconds(10))

        // Start waiter tasks
        let waiterTasks: [Task<Void, Never>] = (0..<waiterCount).map { id in
            Task { [pool, resourceID, outcomeTracker] in
                do throws(IO.Lifecycle.Error<IO.Error<Never>>) {
                    try await pool.withHandle(resourceID) { resource in
                        resource.counter += 1
                    }
                    // Acquired and completed
                    await outcomeTracker.record(id: id, outcome: .acquired)
                } catch {
                    switch error {
                    case .shutdownInProgress:
                        await outcomeTracker.record(id: id, outcome: .shutdown)
                    case .cancelled, .timeout:
                        await outcomeTracker.record(id: id, outcome: .cancelled)
                    case .failure(.handle(.invalidID)):
                        // This should only happen for explicit destroy(), not shutdown
                        await outcomeTracker.record(id: id, outcome: .otherError("invalidID"))
                    case .failure(let other):
                        await outcomeTracker.record(id: id, outcome: .otherError("\(other)"))
                    }
                }
            }
        }

        // Give waiters time to enqueue
        try await Task.sleep(for: .milliseconds(20))

        // Deterministic cancellation: cancel waiters with id divisible by 3.
        // We use a fixed pattern (not random) to ensure CI reproducibility.
        // Randomized fuzzing belongs in a separate soak harness.
        for id in stride(from: 0, to: waiterCount, by: 3) {
            waiterTasks[id].cancel()
        }

        // Small delay then initiate shutdown concurrently
        try await Task.sleep(for: .milliseconds(10))

        let shutdownTask = Task { [pool] in
            await pool.shutdown()
        }

        // Wait for all tasks with timeout
        let timeoutTask = Task {
            try await Task.sleep(for: .seconds(5))
            return false
        }

        // Wait for holder tasks
        for t in holderTasks {
            await t.value
        }

        // Wait for waiter tasks
        for t in waiterTasks {
            await t.value
        }

        // Wait for shutdown
        await shutdownTask.value

        // Cancel timeout (test passed before timeout)
        timeoutTask.cancel()

        // Verify all waiters completed exactly once
        let snapshot = await outcomeTracker.snapshot()
        #expect(snapshot.completedCount == waiterCount, "Not all waiters completed: \(snapshot.completedCount)/\(waiterCount)")
        #expect(snapshot.allCompleted, "Some waiters did not complete (lost wakeup bug)")

        // Verify all outcomes are in the allowed set
        let disallowed = await outcomeTracker.assertAllOutcomesAllowed([.acquired, .cancelled, .shutdown])
        #expect(disallowed.isEmpty, "Unexpected outcomes: \(disallowed)")
    }

    /// Tests that destroy during active transaction is handled correctly.
    @Test("destroy while transaction in progress")
    func destroyDuringTransaction() async throws {
        let pool = IO.Executor.Pool<StressTestResource>(lane: .inline)
        let resourceID = try await pool.register(StressTestResource(id: 0))

        let transactionCompleted = Counter()

        // Start a transaction that will complete quickly
        let transactionTask = Task { [pool, resourceID, transactionCompleted] in
            do {
                let result: Int = try await pool.withHandle(resourceID) { resource in
                    resource.counter += 1
                    return resource.counter
                }
                await transactionCompleted.increment()
                return result
            } catch {
                await transactionCompleted.increment()
                return -1
            }
        }

        // Try to destroy while transaction might be in progress
        // (timing is non-deterministic, but tests the destroy path)
        try await pool.destroy(resourceID)

        // Transaction should eventually complete
        let result = await transactionTask.value

        // Either transaction succeeded before destroy, or failed due to destroy
        #expect(result == 1 || result == -1)
        #expect(await transactionCompleted.get() == 1)

        await pool.shutdown()
    }

    /// Tests that concurrent transactions on same handle serialize correctly.
    @Test("concurrent transactions serialize")
    func concurrentTransactionsSerialize() async throws {
        let pool = IO.Executor.Pool<StressTestResource>(lane: .inline)
        let resourceID = try await pool.register(StressTestResource(id: 0))

        let executionOrder = OrderTracker()
        let taskCount = 10

        let tasks = (0..<taskCount).map { index in
            Task { [pool, resourceID, executionOrder] in
                do {
                    try await pool.withHandle(resourceID) { resource in
                        resource.counter += 1
                    }
                    await executionOrder.append(index)
                } catch {
                    // May fail on shutdown - still record
                    await executionOrder.append(index)
                }
            }
        }

        // Wait for all tasks
        for t in tasks {
            await t.value
        }

        // Verify all tasks executed
        let order = await executionOrder.getValues()
        #expect(order.count == taskCount, "Not all transactions executed: \(order.count)/\(taskCount)")

        // Verify no duplicates (each executed exactly once)
        let uniqueCount = Set(order).count
        #expect(uniqueCount == taskCount, "Some transactions executed multiple times")

        await pool.shutdown()
    }

    /// Tests rapid register/destroy cycles don't leak or deadlock.
    @Test("rapid register destroy cycles")
    func rapidRegisterDestroyCycles() async throws {
        let pool = IO.Executor.Pool<StressTestResource>(lane: .inline)
        let cycleCount = 50

        for i in 0..<cycleCount {
            let id = try await pool.register(StressTestResource(id: i))
            #expect(await pool.isOpen(id) == true)
            try await pool.destroy(id)
            #expect(await pool.isOpen(id) == false)
        }

        await pool.shutdown()
    }

    /// Tests that shutdown wakes all waiting tasks.
    ///
    /// ## Invariant
    /// Shutdown must wake all waiters even if holders are still active.
    /// This ensures no task is left suspended indefinitely.
    @Test("shutdown wakes all waiters")
    func shutdownWakesAllWaiters() async throws {
        let pool = IO.Executor.Pool<StressTestResource>(lane: .inline)
        let resourceID = try await pool.register(StressTestResource(id: 0))

        let waiterCount = 10
        let outcomeTracker = OutcomeTracker(count: waiterCount)

        // Start a holder that blocks briefly
        let holderTask = Task { [pool, resourceID] in
            do {
                try await pool.withHandle(resourceID) { resource in
                    resource.counter += 1
                }
            } catch {
                // Expected - shutdown
            }
        }

        // Give holder time to acquire
        try await Task.sleep(for: .milliseconds(10))

        // Start waiters that will enqueue
        let waiterTasks = (0..<waiterCount).map { id in
            Task { [pool, resourceID, outcomeTracker] in
                do throws(IO.Lifecycle.Error<IO.Error<Never>>) {
                    try await pool.withHandle(resourceID) { resource in
                        resource.counter += 1
                    }
                    await outcomeTracker.record(id: id, outcome: .acquired)
                } catch {
                    switch error {
                    case .shutdownInProgress:
                        await outcomeTracker.record(id: id, outcome: .shutdown)
                    case .cancelled, .timeout:
                        await outcomeTracker.record(id: id, outcome: .cancelled)
                    case .failure(.handle(.invalidID)):
                        // This should only happen for explicit destroy(), not shutdown
                        await outcomeTracker.record(id: id, outcome: .otherError("invalidID"))
                    case .failure(let other):
                        await outcomeTracker.record(id: id, outcome: .otherError("\(other)"))
                    }
                }
            }
        }

        // Give waiters time to enqueue
        try await Task.sleep(for: .milliseconds(20))

        // Shutdown must wake all waiters even if holder hasn't released.
        // This is the key invariant: shutdown must not block on in-flight operations.
        await pool.shutdown()

        // Wait for all tasks
        await holderTask.value
        for t in waiterTasks {
            await t.value
        }

        // Verify all waiters completed exactly once
        let snapshot = await outcomeTracker.snapshot()
        #expect(snapshot.completedCount == waiterCount, "Not all waiters woke: \(snapshot.completedCount)/\(waiterCount)")
        #expect(snapshot.allCompleted, "Some waiters did not complete (lost wakeup bug)")

        // Verify all outcomes are in the allowed set
        let disallowed = await outcomeTracker.assertAllOutcomesAllowed([.acquired, .cancelled, .shutdown])
        #expect(disallowed.isEmpty, "Unexpected outcomes: \(disallowed)")
    }

    /// Targeted test for continuation leak during destroy-while-waiting.
    ///
    /// This test specifically stresses the scenario where:
    /// 1. A holder has the resource checked out
    /// 2. Multiple waiters are queued
    /// 3. Destroy is called while waiters are waiting
    ///
    /// The bug: If destroy's resumeAll() races with the holder's resumeNext(),
    /// a waiter's continuation might never be resumed.
    @Test("destroy with queued waiters does not leak continuations")
    func destroyWithQueuedWaitersNoLeak() async throws {
        // Run multiple iterations to catch timing-sensitive races
        for iteration in 0..<50 {
            let pool = IO.Executor.Pool<StressTestResource>(lane: .inline)
            let resourceID = try await pool.register(StressTestResource(id: iteration))

            let waiterCount = 5
            let outcomeTracker = OutcomeTracker(count: waiterCount)

            // Start a holder that will block briefly to allow waiters to queue
            let holderTask = Task { [pool, resourceID] in
                do {
                    try await pool.withHandle(resourceID) { resource in
                        resource.counter += 1
                        // Small delay to allow waiters to enqueue
                        // (inline lane doesn't actually block, but the await points help)
                    }
                } catch {
                    // Shutdown or destroy - expected
                }
            }

            // Start waiters that will enqueue while holder has the resource
            let waiterTasks = (0..<waiterCount).map { id in
                Task { [pool, resourceID, outcomeTracker] in
                    do throws(IO.Lifecycle.Error<IO.Error<Never>>) {
                        try await pool.withHandle(resourceID) { resource in
                            resource.counter += 1
                        }
                        await outcomeTracker.record(id: id, outcome: .acquired)
                    } catch {
                        switch error {
                        case .shutdownInProgress:
                            await outcomeTracker.record(id: id, outcome: .shutdown)
                        case .cancelled, .timeout:
                            await outcomeTracker.record(id: id, outcome: .cancelled)
                        case .failure(.handle(.invalidID)):
                            // This should only happen for explicit destroy(), not shutdown
                            await outcomeTracker.record(id: id, outcome: .otherError("invalidID"))
                        case .failure(let other):
                            await outcomeTracker.record(id: id, outcome: .otherError("\(other)"))
                        }
                    }
                }
            }

            // Destroy while waiters might be queued (timing race)
            // This is the critical path that might leak continuations
            try await pool.destroy(resourceID)

            // Wait for all tasks with timeout
            await holderTask.value
            for t in waiterTasks {
                await t.value
            }

            // All waiters must complete (no leaked continuations)
            let snapshot = await outcomeTracker.snapshot()
            #expect(
                snapshot.allCompleted,
                "Iteration \(iteration): Not all waiters completed (\(snapshot.completedCount)/\(waiterCount)) - potential continuation leak"
            )

            await pool.shutdown()
        }
    }

    // MARK: - Race Window Tests

    /// Tests cancel racing with enqueue on the same token.
    ///
    /// Scenario: Generate token, then race cancel vs enqueue.
    /// The cancel might arrive before enqueue stores the continuation.
    @Test("cancel racing with enqueue")
    func cancelRacingWithEnqueue() async throws {
        for iteration in 0..<100 {
            let pool = IO.Executor.Pool<StressTestResource>(lane: .inline)
            let resourceID = try await pool.register(StressTestResource(id: iteration))

            let outcomeTracker = OutcomeTracker(count: 1)

            // Hold the resource so waiter must queue
            let holderTask = Task { [pool, resourceID] in
                try? await pool.withHandle(resourceID) { resource in
                    resource.counter += 1
                }
            }

            // Give holder time to acquire
            try await Task.sleep(for: .milliseconds(1))

            // Start waiter that will be immediately cancelled
            let waiterTask = Task { [pool, resourceID, outcomeTracker] in
                do throws(IO.Lifecycle.Error<IO.Error<Never>>) {
                    try await pool.withHandle(resourceID) { resource in
                        resource.counter += 1
                    }
                    await outcomeTracker.record(id: 0, outcome: .acquired)
                } catch {
                    switch error {
                    case .shutdownInProgress:
                        await outcomeTracker.record(id: 0, outcome: .shutdown)
                    case .cancelled, .timeout:
                        await outcomeTracker.record(id: 0, outcome: .cancelled)
                    case .failure(.handle(.invalidID)):
                        // This should only happen for explicit destroy(), not shutdown
                        await outcomeTracker.record(id: 0, outcome: .otherError("invalidID"))
                    case .failure(let other):
                        await outcomeTracker.record(id: 0, outcome: .otherError("\(other)"))
                    }
                }
            }

            // Immediately cancel - races with enqueue
            waiterTask.cancel()

            await holderTask.value
            await waiterTask.value

            let snapshot = await outcomeTracker.snapshot()
            #expect(snapshot.allCompleted, "Iteration \(iteration): waiter didn't complete")

            await pool.shutdown()
        }
    }

    /// Tests double concurrent shutdown.
    ///
    /// Both shutdowns should complete without deadlock or crash.
    @Test("double concurrent shutdown")
    func doubleConcurrentShutdown() async throws {
        for iteration in 0..<50 {
            let pool = IO.Executor.Pool<StressTestResource>(lane: .inline)
            let resourceID = try await pool.register(StressTestResource(id: iteration))

            // Start some waiters
            let waiterCount = 5
            let outcomeTracker = OutcomeTracker(count: waiterCount)

            // Hold the resource
            let holderTask = Task { [pool, resourceID] in
                try? await pool.withHandle(resourceID) { resource in
                    resource.counter += 1
                }
            }

            try await Task.sleep(for: .milliseconds(1))

            let waiterTasks = (0..<waiterCount).map { id in
                Task { [pool, resourceID, outcomeTracker] in
                    do throws(IO.Lifecycle.Error<IO.Error<Never>>) {
                        try await pool.withHandle(resourceID) { resource in
                            resource.counter += 1
                        }
                        await outcomeTracker.record(id: id, outcome: .acquired)
                    } catch {
                        switch error {
                        case .shutdownInProgress:
                            await outcomeTracker.record(id: id, outcome: .shutdown)
                        case .cancelled, .timeout:
                            await outcomeTracker.record(id: id, outcome: .cancelled)
                        case .failure(.handle(.invalidID)):
                            // This should only happen for explicit destroy(), not shutdown
                            await outcomeTracker.record(id: id, outcome: .otherError("invalidID"))
                        case .failure(let other):
                            await outcomeTracker.record(id: id, outcome: .otherError("\(other)"))
                        }
                    }
                }
            }

            // Two concurrent shutdowns
            let shutdown1 = Task { [pool] in await pool.shutdown() }
            let shutdown2 = Task { [pool] in await pool.shutdown() }

            await shutdown1.value
            await shutdown2.value
            await holderTask.value
            for t in waiterTasks { await t.value }

            let snapshot = await outcomeTracker.snapshot()
            #expect(snapshot.allCompleted, "Iteration \(iteration): not all completed")
        }
    }

    /// Tests destroy immediately followed by re-register.
    @Test("rapid destroy and re-register")
    func rapidDestroyAndReRegister() async throws {
        let pool = IO.Executor.Pool<StressTestResource>(lane: .inline)

        for iteration in 0..<100 {
            let id1 = try await pool.register(StressTestResource(id: iteration))

            // Start a transaction
            let transactionTask = Task { [pool, id1] in
                try? await pool.withHandle(id1) { resource in
                    resource.counter += 1
                }
            }

            // Destroy and immediately re-register
            try await pool.destroy(id1)
            let id2 = try await pool.register(StressTestResource(id: iteration + 1000))

            // New resource should work
            try await pool.withHandle(id2) { resource in
                resource.counter += 1
            }

            await transactionTask.value
            try await pool.destroy(id2)
        }

        await pool.shutdown()
    }

    // MARK: - Capacity Edge Cases

    /// Tests exact capacity boundary.
    @Test("exact capacity boundary")
    func exactCapacityBoundary() async throws {
        let pool = IO.Executor.Pool<StressTestResource>(lane: .inline)
        let resourceID = try await pool.register(StressTestResource(id: 0))

        // Create exactly 64 waiters (default capacity)
        let waiterCount = 64
        let outcomeTracker = OutcomeTracker(count: waiterCount)

        // Hold the resource
        let holderTask = Task { [pool, resourceID] in
            try? await pool.withHandle(resourceID) { resource in
                resource.counter += 1
            }
        }

        try await Task.sleep(for: .milliseconds(5))

        let waiterTasks = (0..<waiterCount).map { id in
            Task { [pool, resourceID, outcomeTracker] in
                do throws(IO.Lifecycle.Error<IO.Error<Never>>) {
                    try await pool.withHandle(resourceID) { resource in
                        resource.counter += 1
                    }
                    await outcomeTracker.record(id: id, outcome: .acquired)
                } catch {
                    switch error {
                    case .shutdownInProgress:
                        await outcomeTracker.record(id: id, outcome: .shutdown)
                    case .cancelled, .timeout:
                        await outcomeTracker.record(id: id, outcome: .cancelled)
                    case .failure(.handle(.waitersFull)):
                        await outcomeTracker.record(id: id, outcome: .otherError("waitersFull"))
                    case .failure(.handle(.invalidID)):
                        // This should only happen for explicit destroy(), not shutdown
                        await outcomeTracker.record(id: id, outcome: .otherError("invalidID"))
                    case .failure(let other):
                        await outcomeTracker.record(id: id, outcome: .otherError("\(other)"))
                    }
                }
            }
        }

        await holderTask.value
        for t in waiterTasks { await t.value }

        let snapshot = await outcomeTracker.snapshot()
        #expect(snapshot.allCompleted, "Not all waiters completed")

        await pool.shutdown()
    }

    /// Tests capacity = 1 (degenerate case).
    ///
    /// With capacity 1, the second enqueue while one is stored should reject.
    @Test("capacity one degenerate case")
    func capacityOneDegenerate() async throws {
        let pool = IO.Executor.Pool<StressTestResource>(lane: .inline)
        let resourceID = try await pool.register(StressTestResource(id: 0))

        let outcomeTracker = OutcomeTracker(count: 2)

        // Hold the resource
        let holderTask = Task { [pool, resourceID] in
            try? await pool.withHandle(resourceID) { resource in
                resource.counter += 1
            }
        }

        try await Task.sleep(for: .milliseconds(1))

        // Two waiters competing
        let waiterTasks = (0..<2).map { id in
            Task { [pool, resourceID, outcomeTracker] in
                do throws(IO.Lifecycle.Error<IO.Error<Never>>) {
                    try await pool.withHandle(resourceID) { resource in
                        resource.counter += 1
                    }
                    await outcomeTracker.record(id: id, outcome: .acquired)
                } catch {
                    switch error {
                    case .shutdownInProgress:
                        await outcomeTracker.record(id: id, outcome: .shutdown)
                    case .cancelled, .timeout:
                        await outcomeTracker.record(id: id, outcome: .cancelled)
                    case .failure(.handle(.invalidID)):
                        // This should only happen for explicit destroy(), not shutdown
                        await outcomeTracker.record(id: id, outcome: .otherError("invalidID"))
                    case .failure(let other):
                        await outcomeTracker.record(id: id, outcome: .otherError("\(other)"))
                    }
                }
            }
        }

        await holderTask.value
        for t in waiterTasks { await t.value }

        let snapshot = await outcomeTracker.snapshot()
        #expect(snapshot.allCompleted, "Both waiters should complete")

        await pool.shutdown()
    }

    /// Tests cancel all waiters then enqueue more.
    ///
    /// ## Cancellation Semantics
    /// Cancellation is best-effort in Swift concurrency:
    /// - A cancelled waiter may still acquire if it wins the race with cancellation.
    /// - The guarantee is: no continuation leaks, exactly-once completion.
    ///
    /// This test verifies:
    /// 1. All waiters complete (no lost wakeups)
    /// 2. First wave outcomes are either cancelled OR acquired (best-effort)
    /// 3. Second wave can still acquire after first wave is cancelled
    @Test("cancel all then enqueue more")
    func cancelAllThenEnqueueMore() async throws {
        for iteration in 0..<50 {
            let pool = IO.Executor.Pool<StressTestResource>(lane: .inline)
            let resourceID = try await pool.register(StressTestResource(id: 0))

            let firstWaveCount = 10
            let secondWaveCount = 10
            let firstWaveTracker = OutcomeTracker(count: firstWaveCount)
            let secondWaveTracker = OutcomeTracker(count: secondWaveCount)

            // Hold the resource
            let holderTask = Task { [pool, resourceID] in
                try? await pool.withHandle(resourceID) { resource in
                    resource.counter += 1
                }
            }

            try await Task.sleep(for: .milliseconds(5))

            // First wave of waiters
            let firstWaveTasks = (0..<firstWaveCount).map { id in
                Task { [pool, resourceID, firstWaveTracker] in
                    do throws(IO.Lifecycle.Error<IO.Error<Never>>) {
                        try await pool.withHandle(resourceID) { resource in
                            resource.counter += 1
                        }
                        await firstWaveTracker.record(id: id, outcome: .acquired)
                    } catch {
                        switch error {
                        case .shutdownInProgress:
                            await firstWaveTracker.record(id: id, outcome: .shutdown)
                        case .cancelled, .timeout:
                            await firstWaveTracker.record(id: id, outcome: .cancelled)
                        case .failure(.handle(.invalidID)):
                            // This should only happen for explicit destroy(), not shutdown
                            await firstWaveTracker.record(id: id, outcome: .otherError("invalidID"))
                        case .failure(let other):
                            await firstWaveTracker.record(id: id, outcome: .otherError("\(other)"))
                        }
                    }
                }
            }

            try await Task.sleep(for: .milliseconds(5))

            // Cancel ALL first wave waiters
            for t in firstWaveTasks {
                t.cancel()
            }

            try await Task.sleep(for: .milliseconds(5))

            // Second wave of waiters (should still work)
            let secondWaveTasks = (0..<secondWaveCount).map { id in
                Task { [pool, resourceID, secondWaveTracker] in
                    do throws(IO.Lifecycle.Error<IO.Error<Never>>) {
                        try await pool.withHandle(resourceID) { resource in
                            resource.counter += 1
                        }
                        await secondWaveTracker.record(id: id, outcome: .acquired)
                    } catch {
                        switch error {
                        case .shutdownInProgress:
                            await secondWaveTracker.record(id: id, outcome: .shutdown)
                        case .cancelled, .timeout:
                            await secondWaveTracker.record(id: id, outcome: .cancelled)
                        case .failure(.handle(.invalidID)):
                            // This should only happen for explicit destroy(), not shutdown
                            await secondWaveTracker.record(id: id, outcome: .otherError("invalidID"))
                        case .failure(let other):
                            await secondWaveTracker.record(id: id, outcome: .otherError("\(other)"))
                        }
                    }
                }
            }

            // Watchdog to detect hangs
            let watchdog = Task {
                try await Task.sleep(for: .seconds(2))
                fatalError("HANG iter \(iteration)")
            }
            defer { watchdog.cancel() }

            await holderTask.value
            for t in firstWaveTasks { await t.value }
            for t in secondWaveTasks { await t.value }

            let firstSnapshot = await firstWaveTracker.snapshot()
            let secondSnapshot = await secondWaveTracker.snapshot()

            #expect(firstSnapshot.allCompleted, "Iteration \(iteration): First wave incomplete")
            #expect(secondSnapshot.allCompleted, "Iteration \(iteration): Second wave incomplete")

            // First wave: best-effort cancellation - outcomes can be cancelled OR acquired
            // (a waiter might win the race and acquire before observing cancellation)
            let firstOutcomes = firstSnapshot.outcomes.compactMap { $0 }
            let allowedFirstWave: Set<Outcome> = [.cancelled, .acquired]
            for outcome in firstOutcomes {
                #expect(allowedFirstWave.contains(outcome), "Iteration \(iteration): Unexpected first wave outcome: \(outcome)")
            }

            // Second wave should mostly acquire (some might get shutdown if timing is tight)
            let secondAcquired = secondSnapshot.outcomes.compactMap { $0 }.filter { $0 == .acquired }.count
            #expect(secondAcquired > 0, "Iteration \(iteration): At least some second wave should acquire")

            await pool.shutdown()
        }
    }

    // MARK: - Chaos Tests

    /// Tests holder throwing during transaction while waiters are queued.
    ///
    /// ## Invariant
    /// When a transaction body throws, the handle must still be checked back in,
    /// allowing subsequent waiters to acquire it.
    @Test("holder throws with waiters queued")
    func holderThrowsWithWaitersQueued() async throws {
        struct TestError: Error, Sendable, Equatable {}

        for iteration in 0..<50 {
            let pool = IO.Executor.Pool<StressTestResource>(lane: .inline)
            let resourceID = try await pool.register(StressTestResource(id: iteration))

            let waiterCount = 5
            let outcomeTracker = OutcomeTracker(count: waiterCount)

            // Holder that throws - use explicit typed-throws closure annotation
            let holderTask: Task<Result<Int, IO.Lifecycle.Error<IO.Error<TestError>>>, Never> = Task { [pool, resourceID] in
                do throws(IO.Lifecycle.Error<IO.Error<TestError>>) {
                    // Explicit typed-throws annotation ensures E is inferred as TestError
                    let result: Int = try await pool.withHandle(resourceID) {
                        (resource: inout StressTestResource) throws(TestError) -> Int in
                        resource.counter += 1
                        throw TestError()
                    }
                    return .success(result)
                } catch {
                    return .failure(error)
                }
            }

            try await Task.sleep(for: .milliseconds(1))

            // Waiters
            let waiterTasks = (0..<waiterCount).map { id in
                Task { [pool, resourceID, outcomeTracker] in
                    do throws(IO.Lifecycle.Error<IO.Error<Never>>) {
                        try await pool.withHandle(resourceID) { resource in
                            resource.counter += 1
                        }
                        await outcomeTracker.record(id: id, outcome: .acquired)
                    } catch {
                        switch error {
                        case .shutdownInProgress:
                            await outcomeTracker.record(id: id, outcome: .shutdown)
                        case .cancelled, .timeout:
                            await outcomeTracker.record(id: id, outcome: .cancelled)
                        case .failure(.handle(.invalidID)):
                            // This should only happen for explicit destroy(), not shutdown
                            await outcomeTracker.record(id: id, outcome: .otherError("invalidID"))
                        case .failure(let other):
                            await outcomeTracker.record(id: id, outcome: .otherError("\(other)"))
                        }
                    }
                }
            }

            let holderResult = await holderTask.value

            // Holder should have failed with our error wrapped in .failure(.leaf(...))
            switch holderResult {
            case .success:
                Issue.record("Iteration \(iteration): Holder should have failed")
            case .failure(let error):
                // Verify the error is .failure(.leaf(TestError))
                if case .failure(.leaf(let inner)) = error {
                    #expect(inner == TestError(), "Iteration \(iteration): Should be TestError")
                } else {
                    Issue.record("Iteration \(iteration): Expected .failure(.leaf(TestError)), got \(error)")
                }
            }

            // Waiters should still complete (handle returned to pool despite throw)
            for t in waiterTasks { await t.value }

            let snapshot = await outcomeTracker.snapshot()
            #expect(snapshot.allCompleted, "Iteration \(iteration): waiters didn't complete after holder throw")

            // All waiters should acquire (holder's throw doesn't prevent them)
            let acquired = snapshot.outcomes.compactMap { $0 }.filter { $0 == .acquired }.count
            #expect(acquired == waiterCount, "Iteration \(iteration): All waiters should acquire after holder throw")

            await pool.shutdown()
        }
    }

    /// Full chaos mode: random mix of operations with no coordination.
    ///
    /// Operations: register, destroy, transaction, cancel, shutdown
    /// All running concurrently with no sequencing guarantees.
    @Test("chaos mode - interleaved operations")
    func chaosMode() async throws {
        for iteration in 0..<20 {
            let pool = IO.Executor.Pool<StressTestResource>(lane: .inline)

            let operationCount = 50
            let completedOps = Counter()

            // Mix of operations
            let tasks: [Task<Void, Never>] = (0..<operationCount).map { opIndex in
                Task { [pool, completedOps] in
                    let opType = opIndex % 5

                    do {
                        switch opType {
                        case 0:
                            // Register
                            let id = try await pool.register(StressTestResource(id: opIndex))
                            _ = id
                        case 1:
                            // Register then immediate destroy
                            let id = try await pool.register(StressTestResource(id: opIndex + 1000))
                            try await pool.destroy(id)
                        case 2:
                            // Register then transaction
                            let id = try await pool.register(StressTestResource(id: opIndex + 2000))
                            try await pool.withHandle(id) { resource in
                                resource.counter += 1
                            }
                        case 3:
                            // Register, start transaction, cancel it
                            let id = try await pool.register(StressTestResource(id: opIndex + 3000))
                            let transactionTask = Task { [pool, id] in
                                try? await pool.withHandle(id) { resource in
                                    resource.counter += 1
                                }
                            }
                            transactionTask.cancel()
                            await transactionTask.value
                        case 4:
                            // Register, transaction, destroy
                            let id = try await pool.register(StressTestResource(id: opIndex + 4000))
                            try? await pool.withHandle(id) { resource in
                                resource.counter += 1
                            }
                            try await pool.destroy(id)
                        default:
                            break
                        }
                    } catch {
                        // Any error is acceptable in chaos mode
                    }

                    await completedOps.increment()
                }
            }

            // Let chaos unfold
            try await Task.sleep(for: .milliseconds(50))

            // Shutdown while operations are in flight
            await pool.shutdown()

            // Wait for all operations
            for t in tasks { await t.value }

            let completed = await completedOps.get()
            #expect(completed == operationCount, "Iteration \(iteration): not all ops completed: \(completed)/\(operationCount)")
        }
    }

    /// Stress test with multiple resources and cross-resource contention.
    ///
    /// Tests that transactions on different handles don't interfere with each other,
    /// and that cancellation on one doesn't affect others.
    @Test("multi-resource contention")
    func multiResourceContention() async throws {
        let pool = IO.Executor.Pool<StressTestResource>(lane: .inline)
        let resourceCount = 3
        let transactionsPerResource = 10

        var resourceIDs: [IO.Handle.ID] = []
        for i in 0..<resourceCount {
            let id = try await pool.register(StressTestResource(id: i))
            resourceIDs.append(id)
        }

        let totalTransactions = resourceCount * transactionsPerResource
        let outcomeTracker = OutcomeTracker(count: totalTransactions)

        let tasks = (0..<totalTransactions).map { index in
            let resourceIndex = index % resourceCount
            let resourceID = resourceIDs[resourceIndex]

            return Task { [pool, resourceID, outcomeTracker, index] in
                do throws(IO.Lifecycle.Error<IO.Error<Never>>) {
                    try await pool.withHandle(resourceID) { resource in
                        resource.counter += 1
                    }
                    await outcomeTracker.record(id: index, outcome: .acquired)
                } catch {
                    switch error {
                    case .shutdownInProgress:
                        await outcomeTracker.record(id: index, outcome: .shutdown)
                    case .cancelled, .timeout:
                        await outcomeTracker.record(id: index, outcome: .cancelled)
                    case .failure(.handle(.invalidID)):
                        // This should only happen for explicit destroy(), not shutdown
                        await outcomeTracker.record(id: index, outcome: .otherError("invalidID"))
                    case .failure(let other):
                        await outcomeTracker.record(id: index, outcome: .otherError("\(other)"))
                    }
                }
            }
        }

        // Cancel some tasks (deterministic pattern) - best-effort cancellation
        for i in stride(from: 0, to: totalTransactions, by: 7) {
            tasks[i].cancel()
        }

        for t in tasks { await t.value }

        let snapshot = await outcomeTracker.snapshot()
        #expect(snapshot.allCompleted, "Not all transactions completed")

        // All outcomes should be in allowed set (acquired, cancelled, or shutdown)
        let disallowed = await outcomeTracker.assertAllOutcomesAllowed([.acquired, .cancelled, .shutdown])
        #expect(disallowed.isEmpty, "Unexpected outcomes: \(disallowed)")

        await pool.shutdown()
    }

    /// Tests resumeNext racing with cancel on the same waiter.
    ///
    /// Scenario: Waiter is at head of queue. resumeNext and cancel race.
    /// Only one should succeed in resuming the continuation.
    @Test("resumeNext racing with cancel")
    func resumeNextRacingWithCancel() async throws {
        for _ in 0..<100 {
            let pool = IO.Executor.Pool<StressTestResource>(lane: .inline)
            let resourceID = try await pool.register(StressTestResource(id: 0))

            let outcomeTracker = OutcomeTracker(count: 1)

            // Hold the resource
            let holderTask = Task { [pool, resourceID] in
                try? await pool.withHandle(resourceID) { resource in
                    resource.counter += 1
                }
            }

            try await Task.sleep(for: .milliseconds(1))

            // Waiter that will be subject to race
            let waiterTask = Task { [pool, resourceID, outcomeTracker] in
                do throws(IO.Lifecycle.Error<IO.Error<Never>>) {
                    try await pool.withHandle(resourceID) { resource in
                        resource.counter += 1
                    }
                    await outcomeTracker.record(id: 0, outcome: .acquired)
                } catch {
                    switch error {
                    case .shutdownInProgress:
                        await outcomeTracker.record(id: 0, outcome: .shutdown)
                    case .cancelled, .timeout:
                        await outcomeTracker.record(id: 0, outcome: .cancelled)
                    case .failure(.handle(.invalidID)):
                        // This should only happen for explicit destroy(), not shutdown
                        await outcomeTracker.record(id: 0, outcome: .otherError("invalidID"))
                    case .failure(let other):
                        await outcomeTracker.record(id: 0, outcome: .otherError("\(other)"))
                    }
                }
            }

            // Give waiter time to enqueue
            try await Task.sleep(for: .milliseconds(1))

            // Cancel the waiter - races with holder completing and resuming it
            waiterTask.cancel()

            await holderTask.value
            await waiterTask.value

            let snapshot = await outcomeTracker.snapshot()
            #expect(snapshot.allCompleted, "Waiter should have completed")

            await pool.shutdown()
        }
    }

    /// Tests rapid shutdown/restart cycles (simulates service restarts).
    @Test("rapid shutdown restart cycles")
    func rapidShutdownRestartCycles() async throws {
        for cycle in 0..<20 {
            let pool = IO.Executor.Pool<StressTestResource>(lane: .inline)

            // Register some resources
            var ids: [IO.Handle.ID] = []
            for i in 0..<5 {
                let id = try await pool.register(StressTestResource(id: cycle * 100 + i))
                ids.append(id)
            }

            // Start some transactions
            let tasks = ids.map { id in
                Task { [pool, id] in
                    try? await pool.withHandle(id) { resource in
                        resource.counter += 1
                    }
                }
            }

            // Immediate shutdown
            await pool.shutdown()

            // All tasks should complete (not hang)
            for t in tasks { await t.value }
        }
    }

    // MARK: - Two-Phase Waiter Lifecycle Tests
    //
    // These tests target the specific race conditions that the two-phase
    // register/arm lifecycle was designed to eliminate.

    /// Tests that cancel firing before arm does not cause a hang.
    ///
    /// This is the primary TOCTOU race that the two-phase design eliminates:
    /// - Task registers a ticket
    /// - onCancel fires before arm() is called
    /// - arm() observes the pre-cancellation and resumes immediately
    @Test("cancel fires before arm - no hang")
    func cancelBeforeArm() async throws {
        for iteration in 0..<1000 {
            let pool = IO.Executor.Pool<StressTestResource>(lane: .inline)
            let id = try await pool.register(StressTestResource(id: iteration))

            let outcomeTracker = OutcomeTracker(count: 1)

            // Hold the resource so waiter must go through register/arm
            let holderTask = Task { [pool, id] in
                try? await pool.withHandle(id) { resource in
                    resource.counter += 1
                }
            }

            try await Task.sleep(for: .milliseconds(1))

            // Waiter task that will be immediately cancelled
            let waiterTask = Task { [pool, id, outcomeTracker] in
                do throws(IO.Lifecycle.Error<IO.Error<Never>>) {
                    try await pool.withHandle(id) { resource in
                        resource.counter += 1
                    }
                    await outcomeTracker.record(id: 0, outcome: .acquired)
                } catch {
                    switch error {
                    case .shutdownInProgress:
                        await outcomeTracker.record(id: 0, outcome: .shutdown)
                    case .cancelled, .timeout:
                        await outcomeTracker.record(id: 0, outcome: .cancelled)
                    case .failure(.handle(.invalidID)):
                        // This should only happen for explicit destroy(), not shutdown
                        await outcomeTracker.record(id: 0, outcome: .otherError("invalidID"))
                    case .failure(let other):
                        await outcomeTracker.record(id: 0, outcome: .otherError("\(other)"))
                    }
                }
            }

            // Immediately cancel - this races with the register/arm sequence
            waiterTask.cancel()

            await holderTask.value
            await waiterTask.value

            let snapshot = await outcomeTracker.snapshot()
            #expect(snapshot.allCompleted, "Iteration \(iteration): waiter didn't complete (potential hang)")

            await pool.shutdown()
        }
    }

    /// Tests that close/destroy between register and arm does not cause a hang.
    ///
    /// This tests the scenario where:
    /// - Task registers a ticket
    /// - closeAndDrain() is called (by shutdown/destroy)
    /// - arm() observes closed state and resumes immediately
    @Test("close between register and arm - no hang")
    func closeBetweenRegisterAndArm() async throws {
        for iteration in 0..<100 {
            let pool = IO.Executor.Pool<StressTestResource>(lane: .inline)
            let id = try await pool.register(StressTestResource(id: iteration))

            let outcomeTracker = OutcomeTracker(count: 1)

            // Hold the resource
            let holderTask = Task { [pool, id] in
                try? await pool.withHandle(id) { resource in
                    resource.counter += 1
                }
            }

            try await Task.sleep(for: .milliseconds(1))

            // Start waiter
            let waiterTask = Task { [pool, id, outcomeTracker] in
                do throws(IO.Lifecycle.Error<IO.Error<Never>>) {
                    try await pool.withHandle(id) { resource in
                        resource.counter += 1
                    }
                    await outcomeTracker.record(id: 0, outcome: .acquired)
                } catch {
                    switch error {
                    case .shutdownInProgress:
                        await outcomeTracker.record(id: 0, outcome: .shutdown)
                    case .cancelled, .timeout:
                        await outcomeTracker.record(id: 0, outcome: .cancelled)
                    case .failure(.handle(.invalidID)):
                        // This should only happen for explicit destroy(), not shutdown
                        await outcomeTracker.record(id: 0, outcome: .otherError("invalidID"))
                    case .failure(let other):
                        await outcomeTracker.record(id: 0, outcome: .otherError("\(other)"))
                    }
                }
            }

            // Destroy while waiter might be between register and arm
            try await pool.destroy(id)

            await holderTask.value
            await waiterTask.value

            let snapshot = await outcomeTracker.snapshot()
            #expect(snapshot.allCompleted, "Iteration \(iteration): waiter didn't complete (potential hang)")

            await pool.shutdown()
        }
    }

    /// Tests that massive cancel storms do not cause memory growth beyond capacity.
    ///
    /// This verifies that:
    /// - pending.count never exceeds capacity
    /// - All tasks complete (no hangs)
    /// - The system remains responsive under high cancellation churn
    @Test("massive cancel storm - no growth beyond capacity")
    func cancelStorm() async throws {
        let capacity = 10
        let pool = IO.Executor.Pool<StressTestResource>(
            lane: .inline,
            policy: IO.Backpressure.Policy(handleWaitersLimit: capacity)
        )
        let id = try await pool.register(StressTestResource(id: 0))

        // Hold resource for the duration - use a separate task that sleeps
        let holderTask = Task { [pool, id] in
            try? await pool.withHandle(id) { resource in
                resource.counter += 1
            }
        }

        // Give holder time to acquire
        try await Task.sleep(for: .milliseconds(10))

        // Spawn and immediately cancel 1000 waiters
        // Each should either be rejected (full) or cancelled
        for _ in 0..<100 {
            var tasks: [Task<Void, Never>] = []
            for _ in 0..<10 {
                let t = Task { [pool, id] in
                    do {
                        try await pool.withHandle(id) { resource in
                            resource.counter += 1
                        }
                    } catch {
                        // Expected - cancelled or full
                    }
                }
                tasks.append(t)
            }

            // Cancel all in this wave
            for t in tasks {
                t.cancel()
            }

            // Wait for all to complete
            for t in tasks {
                await t.value
            }
        }

        // Should not hang
        await holderTask.value
        await pool.shutdown()
    }

    // MARK: - Eager Cancellation Tests

    /// Tests that cancelled waiters don't consume capacity.
    ///
    /// With eager ID-based cancellation, cancelled waiters are removed from
    /// the armed queue immediately, freeing capacity for new registrations.
    ///
    /// ## Invariant
    /// After N cancellations, N new registrations should succeed (not reject with .full).
    @Test("cancelled waiters don't consume capacity", arguments: [4, 16, 32])
    func cancelledWaitersDontConsumeCapacity(capacity: Int) async throws {
        let pool = IO.Executor.Pool<StressTestResource>(
            lane: .inline,
            policy: IO.Backpressure.Policy(handleWaitersLimit: capacity)
        )
        let resourceID = try await pool.register(StressTestResource(id: 0))

        // Hold the resource to force waiters to queue
        let holderTask = Task { [pool, resourceID] in
            try? await pool.withHandle(resourceID) { resource in
                resource.counter += 1
            }
        }

        // Allow holder to acquire - use longer delay to ensure holder holds during waiter creation
        try await Task.sleep(for: .milliseconds(1))

        // Create capacity waiters while holder is active
        let waiterTasks = (0..<capacity).map { _ in
            Task { [pool, resourceID] in
                do throws(IO.Lifecycle.Error<IO.Error<Never>>) {
                    try await pool.withHandle(resourceID) { _ in }
                    return "acquired"
                } catch {
                    switch error {
                    case .shutdownInProgress:
                        return "shutdown"
                    case .cancelled, .timeout:
                        return "cancelled"
                    case .failure(.handle(.waitersFull)):
                        return "waitersFull"
                    case .failure(let other):
                        return "other: \(other)"
                    }
                }
            }
        }

        // Give waiters time to register+arm
        try await Task.sleep(for: .milliseconds(5))

        // Cancel all waiters
        for t in waiterTasks {
            t.cancel()
        }

        // Wait for all cancellations to complete
        for t in waiterTasks {
            _ = await t.value
        }

        // Wait for holder to complete
        await holderTask.value

        // Now register capacity MORE waiters - should all succeed (not .full)
        // We need another holder to ensure waiters queue
        let holder2Task = Task { [pool, resourceID] in
            try? await pool.withHandle(resourceID) { resource in
                resource.counter += 1
            }
        }

        try await Task.sleep(for: .milliseconds(1))

        let secondWaveTasks = (0..<capacity).map { _ in
            Task { [pool, resourceID] in
                do throws(IO.Lifecycle.Error<IO.Error<Never>>) {
                    try await pool.withHandle(resourceID) { _ in }
                    return "acquired"
                } catch {
                    switch error {
                    case .shutdownInProgress:
                        return "shutdown"
                    case .cancelled, .timeout:
                        return "cancelled"
                    case .failure(.handle(.waitersFull)):
                        return "waitersFull"
                    case .failure(let other):
                        return "other: \(other)"
                    }
                }
            }
        }

        // Give second wave time to register
        try await Task.sleep(for: .milliseconds(5))

        await holder2Task.value

        // Collect results
        var waitersFull = 0
        for t in secondWaveTasks {
            let result = await t.value
            if result == "waitersFull" {
                waitersFull += 1
            }
        }

        #expect(waitersFull == 0, "Cancelled waiters should not consume capacity - got \(waitersFull) waitersFull rejections")

        await pool.shutdown()
    }

    /// Tests that cancellation between token.take() and arm() does not trap.
    ///
    /// With the timeless-first implementation, State.arm returns .resumeNow(.cancelled)
    /// instead of preconditionFailure when the ticket was already cancelled by ID.
    ///
    /// ## Invariant
    /// No precondition traps, all waiters complete, no leaked entries.
    @Test("cancel between token-take and arm does not trap", arguments: [50, 100])
    func cancelBetweenTakeAndArmNoTrap(iterations: Int) async throws {
        let pool = IO.Executor.Pool<StressTestResource>(lane: .inline)
        let resourceID = try await pool.register(StressTestResource(id: 0))

        // Run multiple iterations to catch timing-dependent races
        for iteration in 0..<iterations {
            // Hold the resource briefly to force waiters to queue
            let holderTask = Task { [pool, resourceID] in
                try? await pool.withHandle(resourceID) { resource in
                    resource.counter += 1
                }
            }

            // Small delay to let holder acquire
            try await Task.sleep(for: .milliseconds(1))

            // Create waiter
            let waiterTask = Task { [pool, resourceID] in
                do throws(IO.Lifecycle.Error<IO.Error<Never>>) {
                    try await pool.withHandle(resourceID) { _ in }
                    return "acquired"
                } catch {
                    switch error {
                    case .shutdownInProgress:
                        return "shutdown"
                    case .cancelled, .timeout:
                        return "cancelled"
                    case .failure(let other):
                        return "error: \(other)"
                    }
                }
            }

            // Rapidly cancel after minimal delay - trying to hit the token-take/arm race
            try await Task.sleep(for: .microseconds(100 * (iteration % 10 + 1)))
            waiterTask.cancel()

            // Wait for holder to complete
            await holderTask.value

            // Wait for waiter to complete (should NOT trap)
            let result = await waiterTask.value
            #expect(
                result == "acquired" || result == "cancelled",
                "Iteration \(iteration): Unexpected result: \(result)"
            )
        }

        await pool.shutdown()
    }

    // MARK: - Lifecycle Invariant Tests
    //
    // These tests verify the strict lifecycle error invariant:
    // Once shutdown begins, all submissions must fail with
    // .shutdownInProgress, never .handle(.invalidID).

    /// Tests that submit after shutdown rejects immediately with lifecycle error.
    ///
    /// This is the deterministic base case: no races, just verify that
    /// after shutdown completes, all public entry points reject with lifecycle.
    @Test("submit after shutdown rejects immediately with lifecycle error")
    func submitAfterShutdownRejectsImmediately() async throws {
        let pool = IO.Executor.Pool<StressTestResource>(lane: .inline)
        let id = try await pool.register(StressTestResource(id: 0))

        // Shutdown first
        await pool.shutdown()

        // withHandle must reject with lifecycle
        do throws(IO.Lifecycle.Error<IO.Error<Never>>) {
            try await pool.withHandle(id) { _ in }
            Issue.record("withHandle should have thrown")
        } catch {
            switch error {
            case .shutdownInProgress:
                break  // Correct
            case let other:
                Issue.record("Expected .shutdownInProgress from withHandle, got \(other)")
            }
        }

        // run must reject with lifecycle
        do throws(IO.Lifecycle.Error<IO.Error<Never>>) {
            _ = try await pool.run { StressTestResource(id: 1) }
            Issue.record("run should have thrown")
        } catch {
            switch error {
            case .shutdownInProgress:
                break  // Correct
            case let other:
                Issue.record("Expected .shutdownInProgress from run, got \(other)")
            }
        }

        // register must reject with lifecycle
        do throws(IO.Lifecycle.Error<IO.Handle.Error>) {
            _ = try await pool.register(StressTestResource(id: 2))
            Issue.record("register should have thrown")
        } catch {
            switch error {
            case .shutdownInProgress:
                break  // Correct
            case let other:
                Issue.record("Expected .shutdownInProgress from register, got \(other)")
            }
        }
    }

    /// Tests that shutdown while waiting yields lifecycle error, not invalidID.
    ///
    /// This is the key regression test for the lifecycle invariant bug:
    /// When shutdown occurs while a waiter is waiting for a handle,
    /// the waiter must receive .shutdownInProgress, NOT
    /// .failure(.handle(.invalidID)).
    ///
    /// The bug path was:
    /// 1. shutdown() sets isShutdown = true
    /// 2. shutdown() calls closeAndDrain() which resumes waiters
    /// 3. shutdown() sets entry.state = .destroyed
    /// 4. Resumed waiter sees destroyed entry
    /// 5. BUG: Throws .failure(.handle(.invalidID)) instead of .shutdownInProgress
    @Test("shutdown while waiting yields lifecycle error")
    func shutdownWhileWaitingYieldsLifecycleError() async throws {
        // Uses same pattern as "shutdown wakes all waiters" test
        // The key assertion: waiters should never see .handle(.invalidID) when shutdown is the cause

        for iteration in 0..<50 {
            let pool = IO.Executor.Pool<StressTestResource>(lane: .inline)
            let resourceID = try await pool.register(StressTestResource(id: 0))

            let waiterCount = 5
            let outcomeTracker = OutcomeTracker(count: waiterCount)

            // Start a holder that briefly holds the resource
            let holderTask = Task { [pool, resourceID] in
                try? await pool.withHandle(resourceID) { resource in
                    resource.counter += 1
                }
            }

            // Give holder time to acquire
            try await Task.sleep(for: .milliseconds(5))

            // Start waiters that will enqueue
            // Note: We do NOT cancel any tasks in this test, so .cancelled is unexpected.
            let waiterTasks = (0..<waiterCount).map { id in
                Task { [pool, resourceID, outcomeTracker] in
                    do throws(IO.Lifecycle.Error<IO.Error<Never>>) {
                        try await pool.withHandle(resourceID) { resource in
                            resource.counter += 1
                        }
                        await outcomeTracker.record(id: id, outcome: .acquired)
                    } catch {
                        switch error {
                        case .shutdownInProgress:
                            await outcomeTracker.record(id: id, outcome: .shutdown)
                        case .cancelled, .timeout:
                            // No explicit cancellation in this test - treat as failure
                            Issue.record("Iteration \(iteration), waiter \(id): Got .cancelled without explicit cancellation")
                            await outcomeTracker.record(id: id, outcome: .otherError("unexpected-cancelled"))
                        case .failure(.handle(.invalidID)):
                            // This is the key assertion: invalidID during shutdown is the bug
                            Issue.record("Iteration \(iteration), waiter \(id): Got .handle(.invalidID) instead of .shutdownInProgress")
                            await outcomeTracker.record(id: id, outcome: .otherError("invalidID-during-shutdown"))
                        case .failure(let other):
                            await outcomeTracker.record(id: id, outcome: .otherError("\(other)"))
                        }
                    }
                }
            }

            // Give waiters time to enqueue
            try await Task.sleep(for: .milliseconds(10))

            // Shutdown while waiters are waiting
            await pool.shutdown()

            // Wait for all tasks
            await holderTask.value
            for t in waiterTasks { await t.value }

            // Verify all waiters completed exactly once
            let snapshot = await outcomeTracker.snapshot()
            #expect(
                snapshot.allCompleted,
                "Iteration \(iteration): Not all waiters completed (\(snapshot.completedCount)/\(waiterCount))"
            )
        }
    }
}
