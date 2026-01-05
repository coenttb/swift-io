////
////  IO.Executor.JobQueue.swift
////  swift-io
////
////  Created by Coen ten Thije Boonkkamp on 28/12/2025.
////
//
//extension IO.Executor {
//    /// Unbounded ring buffer queue for executor jobs.
//    ///
//    /// O(1) enqueue and dequeue. Grows geometrically when full.
//    ///
//    /// ## Thread Safety
//    /// All access must be protected by `Synchronization`.
//    struct JobQueue {
//        private var storage: [UnownedJob?]
//        private var head: Int = 0
//        private var tail: Int = 0
//        private var _count: Int = 0
//
//        init(initialCapacity: Int = 64) {
//            let capacity = max(initialCapacity, 1)
//            self.storage = [UnownedJob?](repeating: nil, count: capacity)
//        }
//
//        var count: Int { _count }
//        var isEmpty: Bool { _count == 0 }
//        var capacity: Int { storage.count }
//
//        /// Enqueue a job. Grows the buffer if needed.
//        mutating func enqueue(_ job: UnownedJob) {
//            if _count >= storage.count {
//                grow()
//            }
//            storage[tail] = job
//            tail = (tail + 1) % storage.count
//            _count += 1
//        }
//
//        /// Dequeue a job, or nil if empty.
//        mutating func dequeue() -> UnownedJob? {
//            guard _count > 0 else { return nil }
//            let job = storage[head]
//            storage[head] = nil
//            head = (head + 1) % storage.count
//            _count -= 1
//            return job
//        }
//
//        /// Double the capacity and rehash existing elements.
//        private mutating func grow() {
//            let oldCapacity = storage.count
//            let newCapacity = oldCapacity * 2
//            var newStorage = [UnownedJob?](repeating: nil, count: newCapacity)
//
//            // Copy elements in order from head to tail
//            for i in 0..<_count {
//                newStorage[i] = storage[(head + i) % oldCapacity]
//            }
//
//            storage = newStorage
//            head = 0
//            tail = _count
//        }
//    }
//}
