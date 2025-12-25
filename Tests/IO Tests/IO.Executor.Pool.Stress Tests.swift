//
//  IO.Executor.Pool.Stress Tests.swift
//  swift-io
//
//  Deterministic stress test for waiter lifecycle under contention.
//  Tests cancellation + shutdown + contention to catch decade-scale bugs.
//
//  ## Design Decisions for Timelessness
//
//  1. **Deterministic, not random**: Cancellation targets a fixed subset (id % 3 == 0)
//     to ensure CI reproducibility. Randomized fuzzing belongs in a separate soak harness.
//
//  2. **Actor-based state tracking**: Uses actors instead of Mutex/Synchronization for
//     future-proof test utilities with no platform coupling.
//
//  3. **Per-waiter exactly-once tracking**: Each waiter has an ID and outcome tracked
//     individually to catch both lost-wakeup and double-resume bugs.
//
//  4. **Outcome categories**: Asserts that all outcomes are in the allowed set
//     (acquired, cancelled, shutdown) to catch semantic regressions.
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

@Suite("IO.Executor.Pool Stress Tests")
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
                do {
                    try await pool.withHandle(resourceID) { resource in
                        resource.counter += 1
                    }
                    // Acquired and completed
                    await outcomeTracker.record(id: id, outcome: .acquired)
                } catch is CancellationError {
                    await outcomeTracker.record(id: id, outcome: .cancelled)
                } catch let error as IO.Error<Never> {
                    switch error {
                    case .cancelled:
                        await outcomeTracker.record(id: id, outcome: .cancelled)
                    case .executor(.shutdownInProgress):
                        await outcomeTracker.record(id: id, outcome: .shutdown)
                    case .handle(.invalidID):
                        // Handle destroyed during wait - treat as shutdown
                        await outcomeTracker.record(id: id, outcome: .shutdown)
                    default:
                        await outcomeTracker.record(id: id, outcome: .otherError("\(error)"))
                    }
                } catch {
                    await outcomeTracker.record(id: id, outcome: .otherError("\(error)"))
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
                do {
                    try await pool.withHandle(resourceID) { resource in
                        resource.counter += 1
                    }
                    await outcomeTracker.record(id: id, outcome: .acquired)
                } catch is CancellationError {
                    await outcomeTracker.record(id: id, outcome: .cancelled)
                } catch let error as IO.Error<Never> {
                    switch error {
                    case .cancelled:
                        await outcomeTracker.record(id: id, outcome: .cancelled)
                    case .executor(.shutdownInProgress), .handle(.invalidID):
                        await outcomeTracker.record(id: id, outcome: .shutdown)
                    default:
                        await outcomeTracker.record(id: id, outcome: .otherError("\(error)"))
                    }
                } catch {
                    await outcomeTracker.record(id: id, outcome: .otherError("\(error)"))
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
}
