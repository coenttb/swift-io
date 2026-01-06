//
//  IO.Blocking.Lane.Abandoning Tests.swift
//  swift-io
//
//  Tests for the fault-tolerant abandoning lane.
//

import IO_Test_Support
import StandardsTestSupport
import Testing

@testable import IO_Blocking

extension IO.Blocking.Lane.Abandoning {
    #TestSuites
}

// MARK: - Unit Tests

extension IO.Blocking.Lane.Abandoning.Test.Unit {
    @Test("abandoning lane has correct capabilities")
    func abandoningLaneCapabilities() async {
        let abandoning = IO.Blocking.Lane.abandoning()
        #expect(abandoning.lane.capabilities.executesOnDedicatedThreads == true)
        #expect(abandoning.lane.capabilities.executionSemantics == .abandonOnExecutionTimeout)
        await abandoning.lane.shutdown()
    }

    @Test("abandoning lane executes simple operation")
    func abandoningLaneExecutesSimpleOperation() async throws {
        let abandoning = IO.Blocking.Lane.abandoning()

        let result: Result<Int, Never> = try await abandoning.lane.run(deadline: nil) { 42 }
        #expect(try result.get() == 42)

        await abandoning.lane.shutdown()
    }

    @Test("abandoning lane executes multiple operations")
    func abandoningLaneExecutesMultipleOperations() async throws {
        let abandoning = IO.Blocking.Lane.abandoning(.init(workers: 2))

        for i in 0..<10 {
            let result: Result<Int, Never> = try await abandoning.lane.run(deadline: nil) { i * 2 }
            #expect(try result.get() == i * 2)
        }

        await abandoning.lane.shutdown()
    }

    @Test("metrics reflect completed operations")
    func metricsReflectCompletedOperations() async throws {
        let abandoning = IO.Blocking.Lane.abandoning(.init(workers: 1))

        // Execute a few operations
        for _ in 0..<5 {
            let _: Result<Int, Never> = try await abandoning.lane.run(deadline: nil) { 1 }
        }

        let metrics = abandoning.metrics()
        #expect(metrics.completedTotal == 5)
        #expect(metrics.abandonedWorkers == 0)

        await abandoning.lane.shutdown()
    }

    @Test("shutdown completes gracefully")
    func shutdownCompletesGracefully() async {
        let abandoning = IO.Blocking.Lane.abandoning()
        await abandoning.lane.shutdown()
        // No hang = success
    }
}

// MARK: - Timeout Tests

extension IO.Blocking.Lane.Abandoning.Test.EdgeCase {
    @Test("operation timeout abandons worker", .timeLimit(.minutes(1)))
    func operationTimeoutAbandonsWorker() async throws {
        // Short timeout for testing
        let abandoning = IO.Blocking.Lane.abandoning(.init(
            workers: 1,
            maxWorkers: 2,
            executionTimeout: .milliseconds(500)
        ))

        // Create a barrier that will never be signaled
        let barrier = Barrier(count: 2)  // Needs 2 but only 1 will arrive

        // Submit blocking operation that will timeout
        do {
            let _: Result<Int, Never> = try await abandoning.lane.run(deadline: nil) {
                // This will block until timeout
                _ = barrier.arriveAndWait(timeout: .seconds(30))
                return 42
            }
            Issue.record("Expected timeout error")
        } catch {
            #expect(error == .timeout)
        }

        // Verify worker was abandoned
        let metrics = abandoning.metrics()
        #expect(metrics.abandonedWorkers == 1)
        #expect(metrics.abandonedTotal == 1)

        await abandoning.lane.shutdown()
    }

    @Test("abandoned worker is replaced", .timeLimit(.minutes(1)))
    func abandonedWorkerIsReplaced() async throws {
        let abandoning = IO.Blocking.Lane.abandoning(.init(
            workers: 1,
            maxWorkers: 4,
            executionTimeout: .milliseconds(300)
        ))

        // First operation will timeout
        let barrier = Barrier(count: 2)
        do {
            let _: Result<Int, Never> = try await abandoning.lane.run(deadline: nil) {
                _ = barrier.arriveAndWait(timeout: .seconds(30))
                return 1
            }
        } catch {
            #expect(error == .timeout)
        }

        // Replacement should have been spawned - verify we can still execute work
        let result: Result<Int, Never> = try await abandoning.lane.run(deadline: nil) { 42 }
        #expect(try result.get() == 42)

        let metrics = abandoning.metrics()
        #expect(metrics.abandonedWorkers == 1)
        #expect(metrics.spawnedWorkers >= 2)  // Original + replacement

        await abandoning.lane.shutdown()
    }

    @Test("multiple timeouts spawn multiple replacements", .timeLimit(.minutes(1)))
    func multipleTimeoutsSpawnMultipleReplacements() async throws {
        let abandoning = IO.Blocking.Lane.abandoning(.init(
            workers: 1,
            maxWorkers: 10,
            executionTimeout: .milliseconds(200)
        ))

        // Trigger 3 timeouts sequentially
        for _ in 0..<3 {
            let barrier = Barrier(count: 2)
            do {
                let _: Result<Int, Never> = try await abandoning.lane.run(deadline: nil) {
                    _ = barrier.arriveAndWait(timeout: .seconds(30))
                    return 1
                }
            } catch {
                #expect(error == .timeout)
            }
        }

        // Should still be able to work
        let result: Result<Int, Never> = try await abandoning.lane.run(deadline: nil) { 100 }
        #expect(try result.get() == 100)

        let metrics = abandoning.metrics()
        #expect(metrics.abandonedWorkers == 3)
        #expect(metrics.spawnedWorkers >= 4)  // 1 original + 3 replacements

        await abandoning.lane.shutdown()
    }
}

// MARK: - Cancellation Tests

extension IO.Blocking.Lane.Abandoning.Test.EdgeCase {
    @Test("cancellation before execution")
    func cancellationBeforeExecution() async {
        let abandoning = IO.Blocking.Lane.abandoning()

        let task = Task {
            try await Task.sleep(for: .milliseconds(100))
            let result: Result<Int, Never> = try await abandoning.lane.run(deadline: nil) { 42 }
            return result
        }
        task.cancel()

        do {
            _ = try await task.value
            Issue.record("Expected cancellation")
        } catch {
            // Cancellation expected
        }

        await abandoning.lane.shutdown()
    }
}

// MARK: - Concurrent Tests

extension IO.Blocking.Lane.Abandoning.Test.Performance {
    @Test("concurrent operations complete correctly", .timeLimit(.minutes(1)))
    func concurrentOperationsCompleteCorrectly() async throws {
        let abandoning = IO.Blocking.Lane.abandoning(.init(workers: 4))

        // Submit many concurrent operations
        await withTaskGroup(of: Int.self) { group in
            for i in 0..<100 {
                group.addTask {
                    do {
                        let result: Result<Int, Never> = try await abandoning.lane.run(deadline: nil) { i }
                        return try result.get()
                    } catch {
                        return -1
                    }
                }
            }

            var results: [Int] = []
            for await result in group {
                results.append(result)
            }

            // All should succeed
            #expect(results.filter { $0 >= 0 }.count == 100)
        }

        let metrics = abandoning.metrics()
        #expect(metrics.completedTotal == 100)

        await abandoning.lane.shutdown()
    }
}
