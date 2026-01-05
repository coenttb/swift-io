//
//  IO.Blocking.Threads.Job.Queue.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 24/12/2025.
//

extension IO.Blocking.Threads.Job {
    /// A bounded circular buffer queue for jobs.
    ///
    /// Uses `Kernel.RingBuffer<Instance>` internally for O(1) operations.
    ///
    /// ## Thread Safety
    /// All access must be protected by Worker.State.lock.
    ///
    /// ## Memory Management
    /// Uses optional storage to avoid needing placeholder jobs.
    /// Empty slots are nil, which allows ARC to release job resources.
    struct Queue {
        private var ring: Kernel.RingBuffer<Instance>

        init(capacity: Int) {
            self.ring = Kernel.RingBuffer(capacity: capacity)
        }

        var count: Int { ring.count }
        var isEmpty: Bool { ring.isEmpty }
        var isFull: Bool { ring.isFull }

        mutating func enqueue(_ job: Instance) {
            ring.enqueueUnchecked(job)
        }

        mutating func dequeue() -> Instance? {
            ring.dequeue()
        }

        mutating func drain() -> [Instance] {
            ring.drain()
        }
    }
}
