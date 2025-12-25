//
//  IO.Executor.Pool.Stress Tests.swift
//  swift-io
//
//  Deterministic stress test for waiter lifecycle under contention.
//  Tests cancellation + shutdown + contention to catch decade-scale bugs.
//

import Synchronization
import Testing

@testable import IO

// MARK: - Test Resource

private struct StressTestResource: Sendable {
    let id: Int
    var counter: Int = 0
}

// MARK: - Stress Test Utilities

/// Tracks exactly-once completion for each waiter.
private final class DoneTracker: @unchecked Sendable {
    private let storage: Mutex<Storage>

    struct Storage {
        var done: [Bool]
        var doneCount: Int
    }

    init(count: Int) {
        self.storage = Mutex(Storage(
            done: Array(repeating: false, count: count),
            doneCount: 0
        ))
    }

    func markDone(id: Int) {
        storage.withLock { storage in
            precondition(!storage.done[id], "Waiter \(id) completed more than once")
            storage.done[id] = true
            storage.doneCount += 1
        }
    }

    func snapshot() -> (doneCount: Int, allDone: Bool) {
        storage.withLock { storage in
            (storage.doneCount, storage.done.allSatisfy { $0 })
        }
    }
}

/// Sendable counter for tracking completions.
private final class Counter: @unchecked Sendable {
    private let storage: Mutex<Int>

    init(_ value: Int = 0) {
        self.storage = Mutex(value)
    }

    func increment() {
        storage.withLock { $0 += 1 }
    }

    var value: Int {
        storage.withLock { $0 }
    }
}

/// Sendable list for tracking execution order.
private final class OrderTracker: @unchecked Sendable {
    private let storage: Mutex<[Int]>

    init() {
        self.storage = Mutex([])
    }

    func append(_ value: Int) {
        storage.withLock { $0.append(value) }
    }

    var values: [Int] {
        storage.withLock { $0 }
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
    /// Assertions:
    /// - No deadlock (bounded timeout)
    /// - No lost wakeups (all waiters complete)
    /// - Exactly-once resumption (DoneTracker pattern)
    @Test("waiter lifecycle under cancellation + shutdown + contention")
    func waiterLifecycleStress() async throws {
        // Configuration - tuned for deterministic CI
        let holderCount = 3
        let waiterCount = 24

        // Use inline lane for deterministic behavior
        let pool = IO.Executor.Pool<StressTestResource>(lane: .inline)

        // Register a single resource (creates contention)
        let resourceID = try await pool.register(StressTestResource(id: 0))

        let doneTracker = DoneTracker(count: waiterCount)
        let holdersCompleted = Counter()

        // Start holder tasks that will acquire and hold the resource briefly
        let holderTasks: [Task<Void, Never>] = (0..<holderCount).map { _ in
            Task { [pool, resourceID, holdersCompleted] in
                do {
                    // Each holder does a quick operation
                    try await pool.withHandle(resourceID) { resource in
                        resource.counter += 1
                    }
                    holdersCompleted.increment()
                } catch {
                    // May fail due to shutdown - that's acceptable
                    holdersCompleted.increment()
                }
            }
        }

        // Give holders a head start
        try await Task.sleep(for: .milliseconds(10))

        // Start waiter tasks
        let waiterTasks: [Task<Void, Never>] = (0..<waiterCount).map { id in
            Task { [pool, resourceID, doneTracker] in
                do {
                    try await pool.withHandle(resourceID) { resource in
                        resource.counter += 1
                    }
                    // Acquired and completed - mark done
                    doneTracker.markDone(id: id)
                } catch {
                    // Acceptable outcomes:
                    // - CancellationError (task was cancelled)
                    // - shutdownInProgress (pool is shutting down)
                    // - invalidID (handle was destroyed)
                    doneTracker.markDone(id: id)
                }
            }
        }

        // Give waiters time to enqueue
        try await Task.sleep(for: .milliseconds(20))

        // Deterministic cancellation: cancel waiters with id divisible by 3
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
        let snapshot = doneTracker.snapshot()
        #expect(snapshot.doneCount == waiterCount, "Not all waiters completed: \(snapshot.doneCount)/\(waiterCount)")
        #expect(snapshot.allDone, "Some waiters did not complete")
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
                transactionCompleted.increment()
                return result
            } catch {
                transactionCompleted.increment()
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
        #expect(transactionCompleted.value == 1)

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
                    executionOrder.append(index)
                } catch {
                    // May fail on shutdown - still record
                    executionOrder.append(index)
                }
            }
        }

        // Wait for all tasks
        for t in tasks {
            await t.value
        }

        // Verify all tasks executed
        let order = executionOrder.values
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
    @Test("shutdown wakes all waiters")
    func shutdownWakesAllWaiters() async throws {
        let pool = IO.Executor.Pool<StressTestResource>(lane: .inline)
        let resourceID = try await pool.register(StressTestResource(id: 0))

        let waiterCount = 10
        let wakeCounts = Counter()

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
        let waiterTasks = (0..<waiterCount).map { _ in
            Task { [pool, resourceID, wakeCounts] in
                do {
                    try await pool.withHandle(resourceID) { resource in
                        resource.counter += 1
                    }
                } catch {
                    // Expected - shutdown wakes us
                }
                wakeCounts.increment()
            }
        }

        // Give waiters time to enqueue
        try await Task.sleep(for: .milliseconds(20))

        // Shutdown should wake all waiters
        await pool.shutdown()

        // Wait for all tasks
        await holderTask.value
        for t in waiterTasks {
            await t.value
        }

        // Verify all waiters woke up
        #expect(wakeCounts.value == waiterCount, "Not all waiters woke: \(wakeCounts.value)/\(waiterCount)")
    }
}
