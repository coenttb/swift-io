//
//  IO.Blocking.Threads.Job.Queue.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 24/12/2025.
//

extension IO.Blocking.Threads.Job {
    /// A bounded circular buffer queue for jobs.
    ///
    /// ## Thread Safety
    /// All access must be protected by Worker.State.lock.
    ///
    /// ## Memory Management
    /// Uses optional storage to avoid needing placeholder jobs.
    /// Empty slots are nil, which allows ARC to release job resources.
    struct Queue {
        private var storage: [Instance?]
        private var head: Int = 0
        private var tail: Int = 0
        private var _count: Int = 0
        private let capacity: Int

        init(capacity: Int) {
            self.capacity = max(capacity, 1)
            self.storage = [Instance?](repeating: nil, count: self.capacity)
        }

        var count: Int { _count }
        var isEmpty: Bool { _count == 0 }
        var isFull: Bool { _count >= capacity }

        mutating func enqueue(_ job: Instance) {
            precondition(!isFull, "Queue is full")
            // Invariant: count < capacity implies storage[tail] is nil
            // This catches double-enqueue or accounting corruption
            precondition(storage[tail] == nil, "Queue invariant violated: tail slot is not nil")
            storage[tail] = job
            tail = (tail + 1) % capacity
            _count += 1
        }

        mutating func dequeue() -> Instance? {
            guard _count > 0 else { return nil }
            // Invariant: count > 0 implies storage[head] is non-nil
            // This catches queue corruption early rather than silently dropping jobs
            guard let job = storage[head] else {
                preconditionFailure("Queue invariant violated: count=\(_count) but head slot is nil")
            }
            storage[head] = nil
            head = (head + 1) % capacity
            _count -= 1
            return job
        }

        mutating func drain(all: Void = ()) -> [Instance] {
            var result: [Instance] = []
            result.reserveCapacity(_count)
            while let job = dequeue() {
                result.append(job)
            }
            return result
        }
    }
}
