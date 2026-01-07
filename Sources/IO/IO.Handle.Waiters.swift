//
//  IO.Handle.Waiters.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 24/12/2025.
//

extension IO.Handle {
    /// FIFO ring buffer queue of waiters with synchronous cancellation support.
    ///
    /// ## Thread Safety
    /// The queue itself must be externally synchronized (actor-isolated).
    /// Individual waiters support synchronous cancellation intent from any thread.
    ///
    /// ## Cancellation Model: "Synchronous state flip, actor drains on next touch"
    ///
    /// Each waiter is a `Waiter` cell that can be marked cancelled from any thread.
    /// The `onCancel` handler calls `waiter.cancel()` - synchronous, does NOT resume.
    /// The actor drains waiters via `resumeNext()` or `resumeAll()`, which takes
    /// the continuation and resumes it on the actor executor.
    ///
    /// This ensures:
    /// - All continuation resumption happens on the actor executor
    /// - No "resume under lock" or "resume from arbitrary thread" hazards
    /// - Cancelled waiters are drained and their tasks observe cancellation after wake
    ///
    /// ## Bounded Capacity
    /// Uses a fixed capacity ring buffer. If capacity is exhausted, `enqueue`
    /// returns false (caller should handle gracefully or fail).
    internal struct Waiters: Sendable {
        /// Default capacity for waiter queues.
        internal static let defaultCapacity: Int = 64

        private var storage: [Waiter?]
        private var head: Int = 0
        private var tail: Int = 0
        private var _count: Int = 0
        private let capacity: Int
        private var nextToken: UInt64 = 0

        internal init(capacity: Int = Waiters.defaultCapacity) {
            self.capacity = max(capacity, 1)
            self.storage = [Waiter?](repeating: nil, count: self.capacity)
        }
    }
}

// MARK: - Properties

extension IO.Handle.Waiters {
    internal var count: Int { _count }
    internal var isEmpty: Bool { _count == 0 }
    internal var isFull: Bool { _count >= capacity }
}

// MARK: - Token Generation

extension IO.Handle.Waiters {
    /// Generate a unique token for a new waiter.
    internal mutating func generateToken() -> UInt64 {
        let token = nextToken
        nextToken &+= 1
        return token
    }
}

// MARK: - Enqueue / Dequeue

extension IO.Handle.Waiters {
    /// Enqueue a waiter. Returns false if queue is full.
    ///
    /// - Parameter waiter: The waiter to enqueue.
    /// - Returns: `true` if successfully enqueued.
    internal mutating func enqueue(_ waiter: IO.Handle.Waiter) -> Bool {
        guard _count < capacity else { return false }
        storage[tail] = waiter
        tail = (tail + 1) % capacity
        _count += 1
        return true
    }

    /// Dequeue the next waiter (structural only; no resumption side effects).
    ///
    /// Returns `nil` if the queue is empty.
    ///
    /// ## Nil Slot Handling
    /// Skips nil slots as a defensive measure. In the current implementation,
    /// nil slots should not occur within the active range because:
    /// - `enqueue()` always stores a non-nil waiter
    /// - All dequeue operations null the slot AND decrement `_count` atomically
    ///
    /// The nil-skipping exists to ensure robustness if the invariant is
    /// accidentally violated during future refactoring.
    ///
    /// ## Count Invariants
    /// - `enqueue()` increments `_count` by 1
    /// - This method decrements `_count` by 1 per slot consumed (including nil slots)
    /// - `_count > 0` guarantees the loop terminates even if all slots are nil
    ///
    /// MUST be called on the actor executor.
    internal mutating func dequeue() -> IO.Handle.Waiter? {
        while _count > 0 {
            let waiter = storage[head]
            storage[head] = nil
            head = (head + 1) % capacity
            _count -= 1
            if let waiter {
                return waiter
            }
            // Nil slot (defensive) - skip and continue
        }
        return nil
    }

    /// Dequeue the next armed, non-cancelled waiter without resuming it.
    ///
    /// This is a structural operation with no resumption side effects.
    /// Cancelled/unarmed waiters are re-enqueued; cancellation draining
    /// is centralized in `_checkInHandle`.
    ///
    /// MUST be called on the actor executor.
    internal mutating func dequeueNextArmed() -> IO.Handle.Waiter? {
        var scanned = 0
        let initialCount = _count

        while _count > 0, scanned < initialCount {
            let waiter = storage[head]
            storage[head] = nil
            head = (head + 1) % capacity
            _count -= 1
            scanned += 1

            guard let waiter else { continue }

            // Eligible for reservation: armed, not cancelled, not drained.
            if waiter.isEligibleForReservation {
                return waiter
            }

            // Already completed; drop it.
            if waiter.isDrained {
                continue
            }

            // Not eligible (cancelled or unarmed): preserve in queue.
            _ = enqueue(waiter)
        }

        return nil
    }
}

// MARK: - Resume Operations

extension IO.Handle.Waiters {
    /// Resume exactly one waiter (cancelled or not).
    ///
    /// Drains from head until a waiter's continuation is successfully taken.
    /// Cancelled waiters are drained - their tasks will observe cancellation after wake.
    ///
    /// MUST be called on the actor executor.
    internal mutating func resumeNext() {
        while _count > 0 {
            let waiter = storage[head]
            storage[head] = nil
            head = (head + 1) % capacity
            _count -= 1

            if let waiter = waiter, let result = waiter.take.forResume() {
                // Resume on actor executor - waiter.wasCancelled tells if cancelled
                result.continuation.resume()
                return
            }
            // Waiter was nil or already drained - slot reclaimed, continue
        }
    }

    /// Resume all waiters (cancelled or not).
    ///
    /// Used during shutdown to wake all waiting tasks.
    /// Cancelled waiters are drained - their tasks will observe cancellation after wake.
    ///
    /// MUST be called on the actor executor.
    internal mutating func resumeAll() {
        while _count > 0 {
            if let waiter = storage[head], let result = waiter.take.forResume() {
                result.continuation.resume()
            }
            storage[head] = nil
            head = (head + 1) % capacity
            _count -= 1
        }
    }
}
