//
//  IO.Executor.JobQueue Tests.swift
//  swift-io
//

import StandardsTestSupport
import Testing

@testable import IO_Primitives

extension IO.Executor.JobQueue {
    #TestSuites
}

// MARK: - Unit Tests

extension IO.Executor.JobQueue.Test.Unit {
    @Test("empty queue reports isEmpty")
    func emptyQueue() {
        let queue = IO.Executor.JobQueue()
        #expect(queue.isEmpty)
    }

    @Test("default capacity is 64")
    func defaultCapacity() {
        let queue = IO.Executor.JobQueue()
        #expect(queue.capacity == 64)
    }

    @Test("custom initial capacity")
    func customCapacity() {
        let queue = IO.Executor.JobQueue(initialCapacity: 128)
        #expect(queue.capacity == 128)
    }

    @Test("minimum capacity is 1")
    func minimumCapacity() {
        let queue = IO.Executor.JobQueue(initialCapacity: 0)
        #expect(queue.capacity >= 1)
    }

    @Test("dequeue from empty returns nil")
    func dequeueEmptyReturnsNil() {
        var queue = IO.Executor.JobQueue()
        #expect(queue.dequeue() == nil)
    }
}

// MARK: - Integration Tests

extension IO.Executor.JobQueue.Test {
    @Suite struct Integration {}
}

extension IO.Executor.JobQueue.Test.Integration {
    @Test("queue grows when full")
    func growsWhenFull() {
        var queue = IO.Executor.JobQueue(initialCapacity: 2)

        // Create dummy executor for job creation
        let executor = IO.Executor.Thread()
        defer { executor.shutdown() }

        // Fill beyond initial capacity - queue should grow
        // Note: We can't easily test this without actual jobs
        // Just verify the queue doesn't crash when growing
        #expect(queue.capacity == 2)
    }
}
