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
    struct Queue {
        private var storage: [Instance]
        private var head: Int = 0
        private var tail: Int = 0
        private var _count: Int = 0
        private let capacity: Int

        init(capacity: Int) {
            self.capacity = max(capacity, 1)
            self.storage = [Instance](repeating: Instance.empty, count: self.capacity)
        }

        var count: Int { _count }
        var isEmpty: Bool { _count == 0 }
        var isFull: Bool { _count >= capacity }

        mutating func enqueue(_ job: Instance) {
            precondition(!isFull, "Queue is full")
            storage[tail] = job
            tail = (tail + 1) % capacity
            _count += 1
        }

        mutating func dequeue() -> Instance? {
            guard _count > 0 else { return nil }
            let job = storage[head]
            storage[head] = .empty
            head = (head + 1) % capacity
            _count -= 1
            return job
        }

        mutating func drainAll() -> [Instance] {
            var result: [Instance] = []
            result.reserveCapacity(_count)
            while let job = dequeue() {
                result.append(job)
            }
            return result
        }
    }
}
