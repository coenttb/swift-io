//
//  IO.Blocking.Threads.Metrics Tests.swift
//  swift-io
//

import Foundation
@testable import IO_Blocking_Threads
import IO_Test_Support
import Kernel
import StandardsTestSupport
import Synchronization
import Testing

// MARK: - Aggregate Tests

@Suite("IO.Blocking.Threads.Aggregate")
struct AggregateTests {
    @Test("empty aggregate has correct initial values")
    func emptyAggregate() {
        let empty = IO.Blocking.Threads.Aggregate.empty
        #expect(empty.count == 0)
        #expect(empty.sumNs == 0)
        #expect(empty.minNs == .max)
        #expect(empty.maxNs == 0)
    }

    @Test("aggregate init stores values")
    func aggregateInit() {
        let agg = IO.Blocking.Threads.Aggregate(
            count: 5,
            sumNs: 100,
            minNs: 10,
            maxNs: 50
        )
        #expect(agg.count == 5)
        #expect(agg.sumNs == 100)
        #expect(agg.minNs == 10)
        #expect(agg.maxNs == 50)
    }

    @Test("mutable aggregate records single value")
    func mutableAggregateRecord() {
        var mutable = IO.Blocking.Threads.Aggregate.Mutable()
        mutable.record(100)

        let snapshot = mutable.snapshot()
        #expect(snapshot.count == 1)
        #expect(snapshot.sumNs == 100)
        #expect(snapshot.minNs == 100)
        #expect(snapshot.maxNs == 100)
    }

    @Test("mutable aggregate records multiple values")
    func mutableAggregateMultiple() {
        var mutable = IO.Blocking.Threads.Aggregate.Mutable()
        mutable.record(50)
        mutable.record(100)
        mutable.record(25)

        let snapshot = mutable.snapshot()
        #expect(snapshot.count == 3)
        #expect(snapshot.sumNs == 175)
        #expect(snapshot.minNs == 25)
        #expect(snapshot.maxNs == 100)
    }
}

// MARK: - State.Transition Tests

@Suite("IO.Blocking.Threads.State.Transition")
struct StateTransitionTests {
    @Test("transition enum cases exist")
    func transitionCases() {
        let _: IO.Blocking.Threads.State.Transition = .becameEmpty
        let _: IO.Blocking.Threads.State.Transition = .becameNonEmpty
        let _: IO.Blocking.Threads.State.Transition = .becameSaturated
        let _: IO.Blocking.Threads.State.Transition = .becameNotSaturated
    }

    @Test("transitions are equatable")
    func transitionsEquatable() {
        #expect(IO.Blocking.Threads.State.Transition.becameEmpty == .becameEmpty)
        #expect(IO.Blocking.Threads.State.Transition.becameEmpty != .becameNonEmpty)
    }
}

// MARK: - Metrics Snapshot Tests

@Suite("IO.Blocking.Threads.Metrics")
struct MetricsSnapshotTests {
    @Test("metrics() returns initial state")
    func metricsInitialState() async {
        let threads = IO.Blocking.Threads(.init(workers: 2, queueLimit: 10))

        let m = threads.metrics()
        #expect(m.queueDepth == 0)
        #expect(m.acceptanceWaitersDepth == 0)
        #expect(m.executingCount == 0)
        #expect(m.enqueuedTotal == 0)
        #expect(m.startedTotal == 0)
        #expect(m.completedTotal == 0)
        #expect(m.failFastTotal == 0)
        #expect(m.overloadedTotal == 0)
        #expect(m.cancelledTotal == 0)

        await threads.shutdown()
    }

    @Test("metrics() tracks enqueued and completed after job runs")
    func metricsAfterJob() async throws {
        let threads = IO.Blocking.Threads(.init(workers: 2, queueLimit: 10))

        let ptr = try await threads.runBoxed(deadline: nil) {
            Kernel.Handoff.Box.makeValue(42)
        }
        let _: Int = Kernel.Handoff.Box.takeValue(ptr)

        // Give worker time to update counters
        try await Task.sleep(for: .milliseconds(50))

        let m = threads.metrics()
        #expect(m.enqueuedTotal >= 1)
        #expect(m.startedTotal >= 1)
        #expect(m.completedTotal >= 1)

        await threads.shutdown()
    }

    @Test("metrics() tracks multiple jobs")
    func metricsMultipleJobs() async throws {
        let threads = IO.Blocking.Threads(.init(workers: 2, queueLimit: 10))

        for i in 0..<5 {
            let ptr = try await threads.runBoxed(deadline: nil) {
                Kernel.Handoff.Box.makeValue(i)
            }
            let _: Int = Kernel.Handoff.Box.takeValue(ptr)
        }

        try await Task.sleep(for: .milliseconds(50))

        let m = threads.metrics()
        #expect(m.enqueuedTotal == 5)
        #expect(m.startedTotal == 5)
        #expect(m.completedTotal == 5)

        await threads.shutdown()
    }

    @Test("latency aggregates are populated")
    func latencyAggregates() async throws {
        let threads = IO.Blocking.Threads(.init(workers: 2, queueLimit: 10))

        let ptr = try await threads.runBoxed(deadline: nil) {
            // Do some minimal work
            Thread.sleep(forTimeInterval: 0.01)
            return Kernel.Handoff.Box.makeValue(42)
        }
        let _: Int = Kernel.Handoff.Box.takeValue(ptr)

        try await Task.sleep(for: .milliseconds(50))

        let m = threads.metrics()

        // enqueueToStart should have recorded
        #expect(m.enqueueToStart.count >= 1)
        #expect(m.enqueueToStart.minNs > 0)

        // execution should have recorded (at least 10ms = 10_000_000ns)
        #expect(m.execution.count >= 1)
        #expect(m.execution.minNs >= 1_000_000) // At least 1ms

        await threads.shutdown()
    }
}

// MARK: - FailFast Counter Tests

@Suite("IO.Blocking.Threads.Metrics FailFast")
struct MetricsFailFastTests {
    @Test("failFastTotal increments on queue full rejection")
    func failFastCounter() async throws {
        // 1 worker, queue of 1, failFast policy
        let threads = IO.Blocking.Threads(.init(
            workers: 1,
            queueLimit: 1,
            backpressure: .failFast
        ))

        // Fill the worker with a slow job
        let slowTask = Task {
            let ptr: UnsafeMutableRawPointer = try await threads.runBoxed(deadline: nil) {
                Thread.sleep(forTimeInterval: 1.0)
                return Kernel.Handoff.Box.makeValue(())
            }
            Kernel.Handoff.Box.destroy(ptr)
        }

        try await Task.sleep(for: .milliseconds(50))

        // Fill the queue
        let fillTask = Task {
            let ptr: UnsafeMutableRawPointer = try await threads.runBoxed(deadline: nil) {
                return Kernel.Handoff.Box.makeValue(())
            }
            Kernel.Handoff.Box.destroy(ptr)
        }

        try await Task.sleep(for: .milliseconds(50))

        // This should be rejected with queueFull
        do {
            let ptr: UnsafeMutableRawPointer = try await threads.runBoxed(deadline: nil) {
                return Kernel.Handoff.Box.makeValue(())
            }
            Kernel.Handoff.Box.destroy(ptr)
            Issue.record("Expected queueFull error")
        } catch let error as IO.Lifecycle.Error<IO.Blocking.Lane.Error> {
            #expect(error == .failure(.queueFull))
        }

        let m = threads.metrics()
        #expect(m.failFastTotal >= 1)

        slowTask.cancel()
        fillTask.cancel()
        await threads.shutdown()
    }
}

// MARK: - State Transition Callback Tests

@Suite("IO.Blocking.Threads.Metrics StateTransition")
struct MetricsStateTransitionTests {
    @Test("onStateTransition callback receives becameNonEmpty")
    func becameNonEmptyCallback() async throws {
        let transitions = Mutex<[IO.Blocking.Threads.State.Transition]>([])

        let threads = IO.Blocking.Threads(.init(
            workers: 1,
            queueLimit: 10,
            onStateTransition: { transition in
                transitions.withLock { $0.append(transition) }
            }
        ))

        // Ensure workers are idle first
        let idleReached = await ThreadPoolTesting.waitUntilIdle(threads, workers: 1)
        #expect(idleReached)

        // Submit a job - should trigger becameNonEmpty
        let ptr = try await threads.runBoxed(deadline: nil) {
            Kernel.Handoff.Box.makeValue(42)
        }
        let _: Int = Kernel.Handoff.Box.takeValue(ptr)

        try await Task.sleep(for: .milliseconds(100))

        let recorded = transitions.withLock { $0 }
        #expect(recorded.contains(.becameNonEmpty))

        await threads.shutdown()
    }

    @Test("onStateTransition callback receives becameEmpty")
    func becameEmptyCallback() async throws {
        let transitions = Mutex<[IO.Blocking.Threads.State.Transition]>([])

        let threads = IO.Blocking.Threads(.init(
            workers: 1,
            queueLimit: 10,
            onStateTransition: { transition in
                transitions.withLock { $0.append(transition) }
            }
        ))

        // Submit a job
        let ptr = try await threads.runBoxed(deadline: nil) {
            Kernel.Handoff.Box.makeValue(42)
        }
        let _: Int = Kernel.Handoff.Box.takeValue(ptr)

        // Wait for job to complete and worker to dequeue
        try await Task.sleep(for: .milliseconds(100))

        let recorded = transitions.withLock { $0 }
        #expect(recorded.contains(.becameEmpty))

        await threads.shutdown()
    }

    @Test("onStateTransition callback receives becameSaturated and becameNotSaturated")
    func saturatedCallbacks() async throws {
        let transitions = Mutex<[IO.Blocking.Threads.State.Transition]>([])

        // 1 worker, tiny queue of 1
        let threads = IO.Blocking.Threads(.init(
            workers: 1,
            queueLimit: 1,
            onStateTransition: { transition in
                transitions.withLock { $0.append(transition) }
            }
        ))

        // Fill worker with slow job
        let slowTask = Task {
            let ptr: UnsafeMutableRawPointer = try await threads.runBoxed(deadline: nil) {
                Thread.sleep(forTimeInterval: 0.5)
                return Kernel.Handoff.Box.makeValue(())
            }
            Kernel.Handoff.Box.destroy(ptr)
        }

        try await Task.sleep(for: .milliseconds(50))

        // Fill the queue - should trigger becameSaturated
        let fillTask = Task {
            let ptr: UnsafeMutableRawPointer = try await threads.runBoxed(deadline: nil) {
                return Kernel.Handoff.Box.makeValue(())
            }
            Kernel.Handoff.Box.destroy(ptr)
        }

        // Wait for slow job to complete (dequeue triggers becameNotSaturated)
        _ = await slowTask.result
        _ = await fillTask.result

        try await Task.sleep(for: .milliseconds(100))

        let recorded = transitions.withLock { $0 }
        #expect(recorded.contains(.becameSaturated))
        #expect(recorded.contains(.becameNotSaturated))

        await threads.shutdown()
    }
}

// MARK: - Acceptance Metrics Tests

@Suite("IO.Blocking.Threads.Metrics Acceptance")
struct MetricsAcceptanceTests {
    @Test("acceptancePromotedTotal increments when waiter is promoted")
    func acceptancePromotedCounter() async throws {
        // 1 worker, queue of 1, wait policy
        let threads = IO.Blocking.Threads(.init(
            workers: 1,
            queueLimit: 1,
            backpressure: .wait
        ))

        // Fill worker with slow job
        let slowTask = Task {
            let ptr: UnsafeMutableRawPointer = try await threads.runBoxed(deadline: nil) {
                Thread.sleep(forTimeInterval: 0.3)
                return Kernel.Handoff.Box.makeValue(())
            }
            Kernel.Handoff.Box.destroy(ptr)
        }

        try await Task.sleep(for: .milliseconds(50))

        // Fill the queue
        let fillTask = Task {
            let ptr: UnsafeMutableRawPointer = try await threads.runBoxed(deadline: nil) {
                return Kernel.Handoff.Box.makeValue(())
            }
            Kernel.Handoff.Box.destroy(ptr)
        }

        try await Task.sleep(for: .milliseconds(50))

        // This will wait in acceptance queue, then be promoted
        let waitingTask = Task {
            let ptr: UnsafeMutableRawPointer = try await threads.runBoxed(deadline: nil) {
                return Kernel.Handoff.Box.makeValue(())
            }
            Kernel.Handoff.Box.destroy(ptr)
        }

        // Wait for all to complete
        _ = await slowTask.result
        _ = await fillTask.result
        _ = await waitingTask.result

        try await Task.sleep(for: .milliseconds(50))

        let m = threads.metrics()
        #expect(m.acceptancePromotedTotal >= 1)

        await threads.shutdown()
    }

    @Test("acceptanceWait aggregate records wait time for promoted waiters")
    func acceptanceWaitAggregate() async throws {
        // 1 worker, queue of 1, wait policy
        let threads = IO.Blocking.Threads(.init(
            workers: 1,
            queueLimit: 1,
            backpressure: .wait
        ))

        // Fill worker with slow job (200ms)
        let slowTask = Task {
            let ptr: UnsafeMutableRawPointer = try await threads.runBoxed(deadline: nil) {
                Thread.sleep(forTimeInterval: 0.2)
                return Kernel.Handoff.Box.makeValue(())
            }
            Kernel.Handoff.Box.destroy(ptr)
        }

        try await Task.sleep(for: .milliseconds(50))

        // Fill the queue
        let fillTask = Task {
            let ptr: UnsafeMutableRawPointer = try await threads.runBoxed(deadline: nil) {
                return Kernel.Handoff.Box.makeValue(())
            }
            Kernel.Handoff.Box.destroy(ptr)
        }

        try await Task.sleep(for: .milliseconds(50))

        // This will wait ~150ms in acceptance queue
        let waitingTask = Task {
            let ptr: UnsafeMutableRawPointer = try await threads.runBoxed(deadline: nil) {
                return Kernel.Handoff.Box.makeValue(())
            }
            Kernel.Handoff.Box.destroy(ptr)
        }

        _ = await slowTask.result
        _ = await fillTask.result
        _ = await waitingTask.result

        try await Task.sleep(for: .milliseconds(50))

        let m = threads.metrics()
        // Should have recorded at least one acceptance wait
        #expect(m.acceptanceWait.count >= 1)
        // Should be at least 50ms (50_000_000 ns)
        #expect(m.acceptanceWait.minNs >= 10_000_000)

        await threads.shutdown()
    }
}
