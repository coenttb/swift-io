//
//  IO.Blocking.Threads.Acceptance.Queue.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 24/12/2025.
//

import Buffer

extension IO.Blocking.Threads.Acceptance {
    /// A bounded circular buffer queue for acceptance waiters.
    ///
    /// Uses `Buffer.Ring<Waiter>` internally with domain-specific
    /// lazy expiry and ticket-based lookup.
    ///
    /// ## Thread Safety
    /// All access must be protected by Runtime.State.lock.
    ///
    /// ## Invariants
    /// - All mutations must be externally synchronized (actor-isolated or under lock)
    /// - Ring buffer scan uses `count` at entry; concurrent mutations would violate this
    ///
    /// ## Lazy Expiry & Hole Reclamation
    /// Expired and cancelled waiters are not eagerly removed. The `resumed` flag marks
    /// a waiter as processed. `promoteNext()` skips resumed entries, reclaiming their slots.
    /// This ensures:
    /// - Non-expired waiters behind expired ones are not starved (FIFO order preserved)
    /// - Capacity is recovered as resumed entries are drained
    struct Queue {
        private var ring: Buffer.Ring<Waiter>

        init(capacity: Int) {
            self.ring = Buffer.Ring(capacity: capacity)
        }

        var count: Int { ring.count }
        var isEmpty: Bool { ring.isEmpty }
        var isFull: Bool { ring.isFull }
        var capacity: Int { ring.capacity }

        /// Enqueue a waiter. Returns false if queue is full (caller should fail with .overloaded).
        mutating func enqueue(_ waiter: Waiter) -> Bool {
            ring.push(waiter)
        }

        /// Dequeue the next non-resumed waiter, reclaiming resumed entries.
        ///
        /// Skips entries where `resumed == true` or slot is nil, decrementing count
        /// to reclaim capacity.
        mutating func dequeue() -> Waiter? {
            while !ring.isEmpty {
                guard let waiter = ring.pop() else { break }
                if !waiter.resumed {
                    return waiter
                }
                // Resumed entry - slot reclaimed, continue
            }
            return nil
        }

        /// Find a waiter by ticket and mark it resumed. Returns the waiter if found.
        ///
        /// O(n) scan - acceptable with bounded capacity.
        /// The waiter stays in storage until dequeue reclaims its slot.
        ///
        /// Returns the waiter with `resumed = false` so the caller can call `resume*` on it.
        /// The storage copy is marked `resumed = true` so `dequeue` will skip it.
        mutating func markResumed(ticket: IO.Blocking.Ticket) -> Waiter? {
            for i in 0..<ring.count {
                guard let waiter = ring[i], !waiter.resumed else { continue }
                if waiter.ticket == ticket {
                    // Mark storage copy as resumed (so dequeue will skip it)
                    var markedWaiter = waiter
                    markedWaiter.resumed = true
                    ring[i] = markedWaiter
                    // Return original waiter (resumed = false) for caller to resume
                    return waiter
                }
            }
            return nil
        }

        /// Access a waiter by index for in-place mutation (e.g., setting resumed = true).
        ///
        /// Used by external code that iterates and modifies waiters.
        subscript(logicalIndex: Int) -> Waiter? {
            get { ring[logicalIndex] }
            set { ring[logicalIndex] = newValue }
        }

        /// Drain all remaining waiters. Used during shutdown.
        mutating func drain() -> [Waiter] {
            ring.drain()
        }
    }
}
