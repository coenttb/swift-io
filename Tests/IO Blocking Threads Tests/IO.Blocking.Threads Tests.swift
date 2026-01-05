//
//  IO.Blocking.Threads Tests.swift
//  swift-io
//

import Dimension
import Foundation
import IO_Blocking_Threads
import IO_Test_Support
import StandardsTestSupport
import Testing

extension IO.Blocking.Threads {
    #TestSuites
}

// MARK: - Unit Tests

extension IO.Blocking.Threads.Test.Unit {
    @Test("init with default options")
    func initDefaultOptions() async {
        let threads = IO.Blocking.Threads()
        #expect(threads.capabilities.executesOnDedicatedThreads == true)
        #expect(threads.capabilities.guaranteesRunOnceEnqueued == true)
        await threads.shutdown()
    }

    @Test("init with custom options")
    func initCustomOptions() async {
        let options = IO.Blocking.Threads.Options(workers: 2, queueLimit: 64)
        let threads = IO.Blocking.Threads(options)
        #expect(threads.capabilities.executesOnDedicatedThreads == true)
        await threads.shutdown()
    }

    @Test("capabilities are correct")
    func capabilitiesCorrect() async {
        let threads = IO.Blocking.Threads()
        #expect(threads.capabilities.executesOnDedicatedThreads == true)
        #expect(threads.capabilities.guaranteesRunOnceEnqueued == true)
        await threads.shutdown()
    }

    @Test("runBoxed executes operation")
    func runBoxedExecutes() async throws {
        let threads = IO.Blocking.Threads()

        let ptr = try await threads.runBoxed(deadline: nil) {
            IO.Blocking.Box.makeValue(42)
        }
        let result: Int = IO.Blocking.Box.takeValue(ptr)
        #expect(result == 42)

        await threads.shutdown()
    }

    @Test("shutdown completes gracefully")
    func shutdownCompletes() async {
        let threads = IO.Blocking.Threads()
        await threads.shutdown()
        // No hang = success
    }

    @Test("Sendable conformance")
    func sendableConformance() async {
        let threads = IO.Blocking.Threads()
        await Task {
            #expect(threads.capabilities.executesOnDedicatedThreads == true)
        }.value
        await threads.shutdown()
    }
}

// MARK: - Performance Tests

extension IO.Blocking.Threads.Test.Performance {
    @Test("burst parallelism - multiple workers activate on burst submit", .timeLimit(.minutes(1)))
    func burstParallelism() async throws {
        // This test validates the work-conserving property:
        // When multiple jobs burst-arrive while pool is idle, all sleeping workers must wake.
        //
        // Under signal()-on-edge (the bug):
        //   - Only 1 worker wakes on first job
        //   - Barrier never reaches target (arrived stuck at 1)
        //   - Test fails assertion
        //
        // Under broadcast()-on-edge (the fix):
        //   - All sleeping workers wake
        //   - Barrier reaches target (arrived == workerCount)
        //   - Test passes

        let workerCount = 4
        let threads = IO.Blocking.Threads(.init(
            workers: Kernel.Thread.Count(workerCount),
            queueLimit: 64
        ))

        // Warm up: ensure all workers are spawned
        let warmupPtr = try await threads.runBoxed(deadline: .none) {
            IO.Blocking.Box.makeValue(())
        }
        IO.Blocking.Box.destroy(warmupPtr)

        // Wait for all workers to go back to sleep
        let idleReached = await ThreadPoolTesting.waitUntilIdle(
            threads,
            workers: workerCount,
            timeout: .seconds(5)
        )
        #expect(idleReached, "Workers should reach idle state before burst test")

        let preSnapshot = threads.debugSnapshot()
        #expect(preSnapshot.sleepers == workerCount)
        #expect(preSnapshot.queueIsEmpty)

        // Create barrier that requires all workers to arrive
        // Uses pthread-based Barrier from IO_Test_Support
        let barrier = Barrier(count: workerCount)

        // Track if any worker timed out at barrier
        final class TimeoutTracker: @unchecked Sendable {
            var timedOut = false
            let lock = NSLock()

            func markTimeout() {
                lock.lock()
                timedOut = true
                lock.unlock()
            }

            var hasTimedOut: Bool {
                lock.lock()
                defer { lock.unlock() }
                return timedOut
            }
        }
        let timeoutTracker = TimeoutTracker()

        // Burst-submit workerCount jobs using TaskGroup
        // Each job arrives at barrier and waits
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<workerCount {
                group.addTask {
                    let ptr = try! await threads.runBoxed(deadline: .none) {
                        // Each job arrives at barrier and waits
                        let success = barrier.arriveAndWait(timeout: .seconds(5))
                        if !success {
                            // Timeout - only some workers woke up
                            // This indicates signal() instead of broadcast()
                            timeoutTracker.markTimeout()
                        }
                        return IO.Blocking.Box.makeValue(())
                    }
                    IO.Blocking.Box.destroy(ptr)
                }
            }
        }

        await threads.shutdown()

        // The barrier should have reached target count
        // With broadcast(), all sleeping workers wake and reach the barrier.
        // With signal() (the bug), only 1 worker wakes, causing arrivedCount < workerCount.
        let arrivedCount = barrier.arrivedCount
        #expect(!timeoutTracker.hasTimedOut, "No worker should time out at barrier")
        #expect(arrivedCount == workerCount,
            "All \(workerCount) workers should reach barrier, but only \(arrivedCount) did")
    }
}

// MARK: - Edge Cases

extension IO.Blocking.Threads.Test.EdgeCase {
    @Test("multiple sequential operations")
    func multipleSequentialOperations() async throws {
        let threads = IO.Blocking.Threads()

        for i in 0..<10 {
            let ptr = try await threads.runBoxed(deadline: nil) {
                IO.Blocking.Box.makeValue(i)
            }
            let result: Int = IO.Blocking.Box.takeValue(ptr)
            #expect(result == i)
        }

        await threads.shutdown()
    }

    @Test("shutdown before any operations")
    func shutdownBeforeOperations() async {
        let threads = IO.Blocking.Threads()
        await threads.shutdown()
        // No hang = success
    }

    @Test("cancellation during acceptance wait completes without hanging", .timeLimit(.minutes(1)))
    func cancellationDuringAcceptanceWait() async throws {
        // Small queue (1 slot) and 1 worker to force acceptance waiting
        let options = IO.Blocking.Threads.Options(
            workers: 1,
            policy: IO.Backpressure.Policy(
                strategy: .wait,
                laneQueueLimit: 1
            )
        )
        let threads = IO.Blocking.Threads(options)

        // Fill both the worker (in-flight) and the queue (pending)
        // Submit 2 slow jobs: one runs on worker, one fills the queue
        _ = Task {
            let ptr: UnsafeMutableRawPointer = try await threads.runBoxed(deadline: nil) {
                Thread.sleep(forTimeInterval: 2.0)  // Block worker for 2 seconds
                return IO.Blocking.Box.makeValue(())
            }
            IO.Blocking.Box.destroy(ptr)
        }

        // Small delay to ensure slowJob1 is accepted first
        try await Task.sleep(for: .milliseconds(10))

        _ = Task {
            let ptr: UnsafeMutableRawPointer = try await threads.runBoxed(deadline: nil) {
                Thread.sleep(forTimeInterval: 2.0)
                return IO.Blocking.Box.makeValue(())
            }
            IO.Blocking.Box.destroy(ptr)
        }

        // Wait for queue to be full (slowJob1 running + slowJob2 in queue = full)
        try await Task.sleep(for: .milliseconds(100))

        // Now submit a third task - this one MUST wait in acceptance queue
        let waitingTask = Task {
            do {
                let _: UnsafeMutableRawPointer = try await threads.runBoxed(deadline: nil) {
                    return IO.Blocking.Box.makeValue(())
                }
                return false  // Unexpected success
            } catch let error as IO.Blocking.Failure {
                return error == .cancellationRequested
            } catch {
                return false  // Unexpected error type
            }
        }

        // Give it time to register as acceptance waiter
        try await Task.sleep(for: .milliseconds(100))

        // Cancel while waiting for acceptance
        waitingTask.cancel()

        // This should complete promptly (not hang!)
        // Before the fix, this would hang forever
        let wasCancelled = await waitingTask.value
        #expect(wasCancelled == true, "Task should have completed with cancellationRequested")

        // Clean up - just wait for shutdown to handle the slow jobs
        await threads.shutdown()
    }

    @Test("cancel vs complete race - exactly-once resumption", .timeLimit(.minutes(1)))
    func cancelVsCompleteRace() async throws {
        // Tests the atomic context state machine under race conditions.
        // Either cancellation wins or completion wins, but never both.
        let threads = IO.Blocking.Threads(.init(workers: 1, queueLimit: 10))

        // Single iteration to isolate issue
        let task = Task {
            do {
                let ptr: UnsafeMutableRawPointer = try await threads.runBoxed(deadline: nil) {
                    // Minimal work - use Box API for proper ownership
                    IO.Blocking.Box.makeValue(42)
                }
                // Completion won - unbox via Box API
                let value: Int = IO.Blocking.Box.takeValue(ptr)
                return "completed:\(value)"
            } catch let error as IO.Blocking.Failure {
                return "cancelled:\(error)"
            } catch {
                return "unexpected:\(type(of: error))"
            }
        }

        // Cancel immediately to race
        task.cancel()

        let result = await task.value
        // Either outcome is valid
        let isValid = result.hasPrefix("completed:") || result.hasPrefix("cancelled:")
        #expect(isValid, "Expected completed or cancelled, got: \(result)")

        await threads.shutdown()
    }

    @Test("shutdown vs acceptance-waiter race - waiter resumes exactly once", .timeLimit(.minutes(1)))
    func shutdownVsAcceptanceWaiterRace() async throws {
        // Fill queue, put a task into acceptance wait, then initiate shutdown.
        // The waiter must resume exactly once with shutdown error.
        let options = IO.Blocking.Threads.Options(
            workers: 1,
            policy: IO.Backpressure.Policy(
                strategy: .wait,
                laneQueueLimit: 1
            )
        )
        let threads = IO.Blocking.Threads(options)

        // Fill the worker and queue with slow jobs
        _ = Task {
            let ptr: UnsafeMutableRawPointer = try await threads.runBoxed(deadline: nil) {
                Thread.sleep(forTimeInterval: 5.0)  // Long enough to outlast test
                return IO.Blocking.Box.makeValue(())
            }
            IO.Blocking.Box.destroy(ptr)
        }

        try await Task.sleep(for: .milliseconds(10))

        _ = Task {
            let ptr: UnsafeMutableRawPointer = try await threads.runBoxed(deadline: nil) {
                Thread.sleep(forTimeInterval: 5.0)
                return IO.Blocking.Box.makeValue(())
            }
            IO.Blocking.Box.destroy(ptr)
        }

        try await Task.sleep(for: .milliseconds(50))

        // Submit task that will wait in acceptance queue
        let waitingTask = Task {
            do {
                let _: UnsafeMutableRawPointer = try await threads.runBoxed(deadline: nil) {
                    return IO.Blocking.Box.makeValue(())
                }
                return "unexpected-success"
            } catch let error as IO.Blocking.Failure {
                return error == .shutdown ? "shutdown" : "other-failure: \(error)"
            } catch {
                return "unexpected-error: \(error)"
            }
        }

        // Give time to enter acceptance wait
        try await Task.sleep(for: .milliseconds(50))

        // Initiate shutdown while waiter is waiting
        await threads.shutdown()

        // Waiter should have been resumed with shutdown
        let result = await waitingTask.value
        #expect(result == "shutdown", "Expected shutdown error, got: \(result)")
    }
}
