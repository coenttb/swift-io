//
//  IO.Blocking.Threads.Scheduling Tests.swift
//  swift-io
//

import IO_Blocking_Threads
import IO_Test_Support
import Kernel
import Testing

// MARK: - Scheduling Enum Tests

@Suite("IO.Blocking.Threads.Scheduling")
struct SchedulingEnumTests {
    @Test("scheduling enum cases exist")
    func schedulingCases() {
        let _: IO.Blocking.Threads.Scheduling = .fifo
        let _: IO.Blocking.Threads.Scheduling = .lifo
    }

    @Test("scheduling is equatable")
    func schedulingEquatable() {
        #expect(IO.Blocking.Threads.Scheduling.fifo == .fifo)
        #expect(IO.Blocking.Threads.Scheduling.fifo != .lifo)
    }

    @Test("default scheduling is FIFO")
    func defaultSchedulingIsFIFO() {
        let options = IO.Blocking.Threads.Options()
        #expect(options.scheduling == .fifo)
    }
}

// MARK: - FIFO Scheduling Tests

@Suite("IO.Blocking.Threads.Scheduling FIFO")
struct FIFOSchedulingTests {
    @Test("FIFO: first enqueued is first dequeued")
    func fifoOrder() async throws {
        // Single worker ensures sequential processing
        let threads = IO.Blocking.Threads(.init(
            workers: 1,
            queueLimit: 10,
            scheduling: .fifo
        ))

        let results = LockedBox<[String]>([])
        let blockerStarted = Signal()
        let bEnqueued = Signal()
        let cEnqueued = Signal()
        let gate = Gate()

        // Job A: blocker (runs first, holds the worker)
        let taskA = Task {
            let ptr: UnsafeMutableRawPointer = try await threads.runBoxedWithEnqueueCallback(
                deadline: nil,
                onEnqueued: { blockerStarted.signal() }
            ) {
                gate.wait()  // Hold worker until we're ready
                results.withLock { $0.append("A") }
                return Kernel.Handoff.Box.makeValue(())
            }
            Kernel.Handoff.Box.destroy(ptr)
        }

        // Wait for A to start running
        blockerStarted.wait()

        // Job B: enqueued first (while A holds worker)
        let taskB = Task {
            let ptr: UnsafeMutableRawPointer = try await threads.runBoxedWithEnqueueCallback(
                deadline: nil,
                onEnqueued: { bEnqueued.signal() }
            ) {
                results.withLock { $0.append("B") }
                return Kernel.Handoff.Box.makeValue(())
            }
            Kernel.Handoff.Box.destroy(ptr)
        }

        // Wait for B to be enqueued
        bEnqueued.wait()

        // Job C: enqueued second
        let taskC = Task {
            let ptr: UnsafeMutableRawPointer = try await threads.runBoxedWithEnqueueCallback(
                deadline: nil,
                onEnqueued: { cEnqueued.signal() }
            ) {
                results.withLock { $0.append("C") }
                return Kernel.Handoff.Box.makeValue(())
            }
            Kernel.Handoff.Box.destroy(ptr)
        }

        // Wait for C to be enqueued
        cEnqueued.wait()

        // Now queue has: B (first), C (second)
        // Release blocker
        gate.open()

        // Wait for all to complete
        _ = try await taskA.value
        _ = try await taskB.value
        _ = try await taskC.value

        // FIFO: A completes (was running), then B (first in), then C (second in)
        #expect(results.withLock { $0 } == ["A", "B", "C"])

        await threads.shutdown()
    }

    @Test("FIFO: four jobs dequeue in submission order")
    func fifoFourJobs() async throws {
        let threads = IO.Blocking.Threads(.init(
            workers: 1,
            queueLimit: 10,
            scheduling: .fifo
        ))

        let results = LockedBox<[Int]>([])
        let blockerStarted = Signal()
        let allEnqueued = Signal()
        let gate = Gate()

        // Signals for each job's enqueue confirmation
        let enqueueSignals = (1...4).map { _ in Signal() }

        // Blocker job
        let blockerTask = Task {
            let ptr: UnsafeMutableRawPointer = try await threads.runBoxedWithEnqueueCallback(
                deadline: nil,
                onEnqueued: { blockerStarted.signal() }
            ) {
                allEnqueued.wait()  // Wait until all jobs are enqueued
                gate.wait()
                results.withLock { $0.append(0) }
                return Kernel.Handoff.Box.makeValue(())
            }
            Kernel.Handoff.Box.destroy(ptr)
        }

        blockerStarted.wait()

        // Spawn jobs 1-4 and wait for each to be enqueued before spawning next
        var tasks: [Task<Void, any Error>] = []
        for i in 1...4 {
            let index = i
            let signal = enqueueSignals[i - 1]
            let task = Task {
                let ptr: UnsafeMutableRawPointer = try await threads.runBoxedWithEnqueueCallback(
                    deadline: nil,
                    onEnqueued: { signal.signal() }
                ) {
                    results.withLock { $0.append(index) }
                    return Kernel.Handoff.Box.makeValue(())
                }
                Kernel.Handoff.Box.destroy(ptr)
            }
            tasks.append(task)
            signal.wait()  // Wait for this job to be enqueued before spawning next
        }

        // All jobs enqueued in order 1, 2, 3, 4
        allEnqueued.signal()
        gate.open()

        _ = try await blockerTask.value
        for task in tasks {
            _ = try await task.value
        }

        // FIFO: 0 (blocker), then 1, 2, 3, 4 in enqueue order
        #expect(results.withLock { $0 } == [0, 1, 2, 3, 4])

        await threads.shutdown()
    }
}

// MARK: - LIFO Scheduling Tests

@Suite("IO.Blocking.Threads.Scheduling LIFO")
struct LIFOSchedulingTests {
    @Test("LIFO: last enqueued is first dequeued")
    func lifoOrder() async throws {
        // Single worker ensures sequential processing
        let threads = IO.Blocking.Threads(.init(
            workers: 1,
            queueLimit: 10,
            scheduling: .lifo
        ))

        let results = LockedBox<[String]>([])
        let blockerStarted = Signal()
        let bEnqueued = Signal()
        let cEnqueued = Signal()
        let gate = Gate()

        // Job A: blocker (runs first, holds the worker)
        let taskA = Task {
            let ptr: UnsafeMutableRawPointer = try await threads.runBoxedWithEnqueueCallback(
                deadline: nil,
                onEnqueued: { blockerStarted.signal() }
            ) {
                gate.wait()  // Hold worker until we're ready
                results.withLock { $0.append("A") }
                return Kernel.Handoff.Box.makeValue(())
            }
            Kernel.Handoff.Box.destroy(ptr)
        }

        // Wait for A to start running
        blockerStarted.wait()

        // Job B: enqueued first (while A holds worker)
        let taskB = Task {
            let ptr: UnsafeMutableRawPointer = try await threads.runBoxedWithEnqueueCallback(
                deadline: nil,
                onEnqueued: { bEnqueued.signal() }
            ) {
                results.withLock { $0.append("B") }
                return Kernel.Handoff.Box.makeValue(())
            }
            Kernel.Handoff.Box.destroy(ptr)
        }

        // Wait for B to be enqueued
        bEnqueued.wait()

        // Job C: enqueued second (most recent)
        let taskC = Task {
            let ptr: UnsafeMutableRawPointer = try await threads.runBoxedWithEnqueueCallback(
                deadline: nil,
                onEnqueued: { cEnqueued.signal() }
            ) {
                results.withLock { $0.append("C") }
                return Kernel.Handoff.Box.makeValue(())
            }
            Kernel.Handoff.Box.destroy(ptr)
        }

        // Wait for C to be enqueued
        cEnqueued.wait()

        // Now queue has: B (first), C (second/most recent)
        // Release blocker
        gate.open()

        // Wait for all to complete
        _ = try await taskA.value
        _ = try await taskB.value
        _ = try await taskC.value

        // LIFO: A completes (was running), then C (last in), then B (first in)
        #expect(results.withLock { $0 } == ["A", "C", "B"])

        await threads.shutdown()
    }

    @Test("LIFO: four jobs dequeue in reverse submission order")
    func lifoFourJobs() async throws {
        let threads = IO.Blocking.Threads(.init(
            workers: 1,
            queueLimit: 10,
            scheduling: .lifo
        ))

        let results = LockedBox<[Int]>([])
        let blockerStarted = Signal()
        let allEnqueued = Signal()
        let gate = Gate()

        // Signals for each job's enqueue confirmation
        let enqueueSignals = (1...4).map { _ in Signal() }

        // Blocker job
        let blockerTask = Task {
            let ptr: UnsafeMutableRawPointer = try await threads.runBoxedWithEnqueueCallback(
                deadline: nil,
                onEnqueued: { blockerStarted.signal() }
            ) {
                allEnqueued.wait()  // Wait until all jobs are enqueued
                gate.wait()
                results.withLock { $0.append(0) }
                return Kernel.Handoff.Box.makeValue(())
            }
            Kernel.Handoff.Box.destroy(ptr)
        }

        blockerStarted.wait()

        // Spawn jobs 1-4 and wait for each to be enqueued before spawning next
        var tasks: [Task<Void, any Error>] = []
        for i in 1...4 {
            let index = i
            let signal = enqueueSignals[i - 1]
            let task = Task {
                let ptr: UnsafeMutableRawPointer = try await threads.runBoxedWithEnqueueCallback(
                    deadline: nil,
                    onEnqueued: { signal.signal() }
                ) {
                    results.withLock { $0.append(index) }
                    return Kernel.Handoff.Box.makeValue(())
                }
                Kernel.Handoff.Box.destroy(ptr)
            }
            tasks.append(task)
            signal.wait()  // Wait for this job to be enqueued before spawning next
        }

        // All jobs enqueued in order 1, 2, 3, 4
        allEnqueued.signal()
        gate.open()

        _ = try await blockerTask.value
        for task in tasks {
            _ = try await task.value
        }

        // LIFO: 0 (blocker), then 4, 3, 2, 1 in reverse enqueue order
        #expect(results.withLock { $0 } == [0, 4, 3, 2, 1])

        await threads.shutdown()
    }

    @Test("LIFO with explicit option")
    func lifoExplicitOption() async throws {
        let options = IO.Blocking.Threads.Options(
            workers: 1,
            queueLimit: 10,
            scheduling: .lifo
        )
        #expect(options.scheduling == .lifo)

        let threads = IO.Blocking.Threads(options)

        let ptr = try await threads.runBoxed(deadline: nil) {
            Kernel.Handoff.Box.makeValue(42)
        }
        let result: Int = Kernel.Handoff.Box.takeValue(ptr)
        #expect(result == 42)

        await threads.shutdown()
    }
}

// MARK: - Scheduling with Policy Initializer

@Suite("IO.Blocking.Threads.Scheduling Policy Init")
struct SchedulingPolicyInitTests {
    @Test("scheduling works with policy initializer")
    func schedulingWithPolicy() async throws {
        let options = IO.Blocking.Threads.Options(
            workers: 2,
            policy: .default,
            scheduling: .lifo
        )
        #expect(options.scheduling == .lifo)

        let threads = IO.Blocking.Threads(options)

        let ptr = try await threads.runBoxed(deadline: nil) {
            Kernel.Handoff.Box.makeValue(42)
        }
        let result: Int = Kernel.Handoff.Box.takeValue(ptr)
        #expect(result == 42)

        await threads.shutdown()
    }
}
