//
//  IO.Blocking.Threads.Acceptance.Queue.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 24/12/2025.
//

import Buffer

extension IO.Blocking.Threads.Acceptance {
    /// Bounded open-addressing hash table for O(1) ticket lookup.
    ///
    /// ## Design
    /// Uses linear probing with power-of-2 capacity for fast modulo.
    /// Each slot stores an optional reference to a WaiterCell.
    ///
    /// ## Why Not Dictionary
    /// - Dictionary may resize and reallocate on hot paths
    /// - Dictionary uses more memory per entry
    /// - We know the max capacity upfront (bounded queue)
    ///
    /// ## Thread Safety
    /// All access must be protected by Runtime.State.lock.
    struct TicketIndexTable {
        private var storage: [WaiterCell?]
        private let mask: Int  // capacity - 1, for power-of-2 capacity

        init(capacity: Int) {
            // Round up to next power of 2 for fast modulo
            let powerOf2 = 1 << (64 - (capacity - 1).leadingZeroBitCount)
            self.storage = Array(repeating: nil, count: powerOf2)
            self.mask = powerOf2 - 1
        }

        /// Insert a cell into the table. O(1) amortized.
        mutating func insert(_ ticket: IO.Blocking.Ticket, _ cell: WaiterCell) {
            var index = Int(ticket.rawValue) & mask
            while storage[index] != nil {
                index = (index + 1) & mask
            }
            storage[index] = cell
        }

        /// Remove and return the cell for a ticket. O(1) amortized.
        ///
        /// Returns nil if not found.
        mutating func remove(_ ticket: IO.Blocking.Ticket) -> WaiterCell? {
            var index = Int(ticket.rawValue) & mask
            while let cell = storage[index] {
                if cell.ticket == ticket {
                    storage[index] = nil
                    return cell
                }
                index = (index + 1) & mask
            }
            return nil
        }

        /// Remove all entries from the table.
        mutating func removeAll() {
            for i in 0..<storage.count {
                storage[i] = nil
            }
        }
    }
}

extension IO.Blocking.Threads.Acceptance {
    /// A bounded circular buffer queue for acceptance waiters with O(1) cancellation.
    ///
    /// ## Design (WaiterCell + Lazy Skip)
    /// Uses `Buffer.Ring<WaiterCell>` for FIFO ordering and `TicketIndexTable` for
    /// O(1) ticket lookup. When a waiter is cancelled:
    /// 1. Look up cell in index table O(1)
    /// 2. Mark cell as resumed
    /// 3. Cell remains in ring until dequeue (lazy skip)
    ///
    /// This eliminates the O(n) scan in `markResumed`.
    ///
    /// ## Thread Safety
    /// All access must be protected by Runtime.State.lock.
    ///
    /// ## Invariants
    /// - Ring and index table are kept in sync
    /// - Cells are removed from index on dequeue or cancel
    /// - FIFO order is preserved for non-cancelled waiters
    ///
    /// ## Lazy Skip Pattern
    /// Cancelled waiters are marked `resumed = true` but stay in the ring.
    /// `dequeue()` skips them, reclaiming their slots. This ensures:
    /// - O(1) cancellation (no ring mutation)
    /// - FIFO fairness among non-cancelled waiters
    /// - Amortized O(1) dequeue (each cancelled cell skipped once)
    struct Queue {
        private var ring: Buffer.Ring<WaiterCell>
        private var index: TicketIndexTable

        init(capacity: Int) {
            self.ring = Buffer.Ring(capacity: capacity)
            // Index table at 2x capacity for < 0.5 load factor
            self.index = TicketIndexTable(capacity: capacity * 2)
        }

        var count: Int { ring.count }
        var isEmpty: Bool { ring.isEmpty }
        var isFull: Bool { ring.isFull }
        var capacity: Int { ring.capacity }

        /// Enqueue a waiter. Returns false if queue is full (caller should fail with .overloaded).
        mutating func enqueue(_ waiter: Waiter) -> Bool {
            guard !ring.isFull else { return false }
            let cell = WaiterCell(
                ticket: waiter.ticket,
                job: waiter.job,
                deadline: waiter.deadline
            )
            _ = ring.push(cell)
            index.insert(waiter.ticket, cell)
            return true
        }

        /// Dequeue the next non-resumed waiter, reclaiming resumed entries.
        ///
        /// Skips cells where `resumed == true`, amortized O(1).
        /// Each cancelled cell is skipped exactly once.
        mutating func dequeue() -> Waiter? {
            while !ring.isEmpty {
                guard let cell = ring.pop() else { break }
                if cell.resumed {
                    // Already cancelled - skip (lazy reclaim)
                    continue
                }
                // Remove from index table
                _ = index.remove(cell.ticket)
                return Waiter(cell)
            }
            return nil
        }

        /// Find a waiter by ticket and mark it resumed. Returns the waiter if found.
        ///
        /// O(1) lookup via index table.
        /// The cell stays in the ring until dequeue reclaims its slot.
        mutating func markResumed(ticket: IO.Blocking.Ticket) -> Waiter? {
            guard let cell = index.remove(ticket) else { return nil }
            // Create snapshot before marking resumed
            let waiter = Waiter(cell)
            // Mark cell as resumed - dequeue will skip it
            cell.resumed = true
            return waiter
        }

        /// Drain all remaining waiters. Used during shutdown.
        mutating func drain() -> [Waiter] {
            index.removeAll()
            var result: [Waiter] = []
            while let cell = ring.pop() {
                result.append(Waiter(cell))
            }
            return result
        }

        // MARK: - Iteration Support for Deadline Manager

        /// Find the earliest deadline among non-resumed waiters.
        ///
        /// O(n) scan - acceptable as this is only called periodically by deadline manager.
        func findEarliestDeadline() -> IO.Blocking.Deadline? {
            var earliest: IO.Blocking.Deadline?
            for i in 0..<ring.count {
                guard let cell = ring[i], !cell.resumed else { continue }
                if let deadline = cell.deadline {
                    if earliest == nil || deadline < earliest! {
                        earliest = deadline
                    }
                }
            }
            return earliest
        }

        /// Mark expired waiters as resumed and return them for resumption.
        ///
        /// O(n) scan - acceptable as this is only called periodically by deadline manager.
        /// Uses WaiterCell reference semantics to mark cells as resumed in-place.
        mutating func markExpiredResumed() -> [Waiter] {
            var expired: [Waiter] = []

            for i in 0..<ring.count {
                guard let cell = ring[i], !cell.resumed else { continue }
                if let deadline = cell.deadline, deadline.hasExpired {
                    // Create snapshot before marking
                    let waiter = Waiter(cell)
                    // Mark cell as resumed - dequeue will skip it
                    cell.resumed = true
                    // Remove from index table
                    _ = index.remove(cell.ticket)
                    expired.append(waiter)
                }
            }

            return expired
        }
    }
}
