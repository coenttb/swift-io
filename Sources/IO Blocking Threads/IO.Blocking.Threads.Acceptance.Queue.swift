//
//  IO.Blocking.Threads.Acceptance.Queue.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 24/12/2025.
//

extension IO.Blocking.Threads.Acceptance {
    /// A bounded circular buffer queue for acceptance waiters.
    ///
    /// ## Thread Safety
    /// All access must be protected by Worker.State.lock.
    ///
    /// ## Invariants
    /// - All mutations must be externally synchronized (actor-isolated or under lock)
    /// - Ring buffer scan uses `_count` at entry; concurrent mutations would violate this
    ///
    /// ## Lazy Expiry & Hole Reclamation
    /// Expired and cancelled waiters are not eagerly removed. The `resumed` flag marks
    /// a waiter as processed. `promoteNext()` skips resumed entries, reclaiming their slots.
    /// This ensures:
    /// - Non-expired waiters behind expired ones are not starved (FIFO order preserved)
    /// - Capacity is recovered as resumed entries are drained
    struct Queue {
        private var storage: [Waiter?]
        private var head: Int = 0
        private var tail: Int = 0
        private var _count: Int = 0
        let capacity: Int

        init(capacity: Int) {
            self.capacity = max(capacity, 1)
            self.storage = [Waiter?](repeating: nil, count: self.capacity)
        }

        var count: Int { _count }
        var isEmpty: Bool { _count == 0 }
        var isFull: Bool { _count >= capacity }

        /// Enqueue a waiter. Returns false if queue is full (caller should fail with .overloaded).
        mutating func enqueue(_ waiter: Waiter) -> Bool {
            guard _count < capacity else { return false }
            storage[tail] = waiter
            tail = (tail + 1) % capacity
            _count += 1
            return true
        }

        /// Dequeue the next non-resumed waiter, reclaiming resumed entries.
        ///
        /// Skips entries where `resumed == true` or slot is nil, decrementing count
        /// to reclaim capacity.
        mutating func dequeue() -> Waiter? {
            while _count > 0 {
                let waiter = storage[head]
                storage[head] = nil
                head = (head + 1) % capacity
                _count -= 1

                if let waiter = waiter, !waiter.resumed {
                    return waiter
                }
                // Resumed or nil entry - slot reclaimed, continue
            }
            return nil
        }

        /// Find a waiter by ticket and mark it resumed. Returns the waiter if found.
        ///
        /// O(n) scan - acceptable with bounded capacity.
        /// The waiter stays in storage until dequeue reclaims its slot.
        mutating func markResumed(ticket: IO.Blocking.Threads.Ticket) -> Waiter? {
            var idx = head
            var remaining = _count
            while remaining > 0 {
                if var waiter = storage[idx], waiter.ticket == ticket, !waiter.resumed {
                    waiter.resumed = true
                    storage[idx] = waiter
                    return waiter
                }
                idx = (idx + 1) % capacity
                remaining -= 1
            }
            return nil
        }

        /// Access a waiter by index for in-place mutation (e.g., setting resumed = true).
        ///
        /// Used by external code that iterates and modifies waiters.
        subscript(logicalIndex: Int) -> Waiter? {
            get {
                guard logicalIndex < _count else { return nil }
                let actualIndex = (head + logicalIndex) % capacity
                return storage[actualIndex]
            }
            set {
                guard logicalIndex < _count else { return }
                let actualIndex = (head + logicalIndex) % capacity
                storage[actualIndex] = newValue
            }
        }

        /// Drain all remaining waiters. Used during shutdown.
        mutating func drainAll() -> [Waiter] {
            var result: [Waiter] = []
            result.reserveCapacity(_count)
            while _count > 0 {
                if let waiter = storage[head] {
                    result.append(waiter)
                }
                storage[head] = nil
                head = (head + 1) % capacity
                _count -= 1
            }
            return result
        }
    }
}
