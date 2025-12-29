//
//  IO.Blocking.Threads Tests.swift
//  swift-io
//

import Foundation
import StandardsTestSupport
import Testing

@testable import IO_Blocking_Threads

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
            let value = 42
            let p = UnsafeMutablePointer<Int>.allocate(capacity: 1)
            p.initialize(to: value)
            return UnsafeMutableRawPointer(p)
        }
        let result = ptr.assumingMemoryBound(to: Int.self).pointee
        ptr.deallocate()
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

// MARK: - Edge Cases

extension IO.Blocking.Threads.Test.EdgeCase {
    @Test("multiple sequential operations")
    func multipleSequentialOperations() async throws {
        let threads = IO.Blocking.Threads()

        for i in 0..<10 {
            let ptr = try await threads.runBoxed(deadline: nil) {
                let p = UnsafeMutablePointer<Int>.allocate(capacity: 1)
                p.initialize(to: i)
                return UnsafeMutableRawPointer(p)
            }
            let result = ptr.assumingMemoryBound(to: Int.self).pointee
            ptr.deallocate()
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
                return UnsafeMutableRawPointer.allocate(byteCount: 1, alignment: 1)
            }
            ptr.deallocate()
        }

        // Small delay to ensure slowJob1 is accepted first
        try await Task.sleep(for: .milliseconds(10))

        _ = Task {
            let ptr: UnsafeMutableRawPointer = try await threads.runBoxed(deadline: nil) {
                Thread.sleep(forTimeInterval: 2.0)
                return UnsafeMutableRawPointer.allocate(byteCount: 1, alignment: 1)
            }
            ptr.deallocate()
        }

        // Wait for queue to be full (slowJob1 running + slowJob2 in queue = full)
        try await Task.sleep(for: .milliseconds(100))

        // Now submit a third task - this one MUST wait in acceptance queue
        let waitingTask = Task {
            do {
                let _: UnsafeMutableRawPointer = try await threads.runBoxed(deadline: nil) {
                    return UnsafeMutableRawPointer.allocate(byteCount: 1, alignment: 1)
                }
                return false // Unexpected success
            } catch let error as IO.Blocking.Failure {
                return error == .cancellationRequested
            } catch {
                return false // Unexpected error type
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
}
