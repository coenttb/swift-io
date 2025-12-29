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
    public struct Waiters: Sendable {
        /// Default capacity for waiter queues.
        public static let defaultCapacity: Int = 64

        private var storage: [Waiter?]
        private var head: Int = 0
        private var tail: Int = 0
        private var _count: Int = 0
        private let capacity: Int
        private var nextToken: UInt64 = 0

        public init(capacity: Int = Waiters.defaultCapacity) {
            self.capacity = max(capacity, 1)
            self.storage = [Waiter?](repeating: nil, count: self.capacity)
        }

        public var count: Int { _count }
        public var isEmpty: Bool { _count == 0 }
        public var isFull: Bool { _count >= capacity }

        /// Generate a unique token for a new waiter.
        public mutating func generateToken() -> UInt64 {
            let token = nextToken
            nextToken &+= 1
            return token
        }

        /// Enqueue a waiter. Returns false if queue is full.
        ///
        /// - Parameter waiter: The waiter to enqueue.
        /// - Returns: `true` if successfully enqueued.
        public mutating func enqueue(_ waiter: Waiter) -> Bool {
            guard _count < capacity else { return false }
            storage[tail] = waiter
            tail = (tail + 1) % capacity
            _count += 1
            return true
        }

        /// Resume exactly one waiter (cancelled or not).
        ///
        /// Drains from head until a waiter's continuation is successfully taken.
        /// Cancelled waiters are drained - their tasks will observe cancellation after wake.
        ///
        /// MUST be called on the actor executor.
        public mutating func resumeNext() {
            while _count > 0 {
                let waiter = storage[head]
                storage[head] = nil
                head = (head + 1) % capacity
                _count -= 1

                if let waiter = waiter, let result = waiter.takeForResume() {
                    // Resume on actor executor - waiter.wasCancelled tells if cancelled
                    result.continuation.resume()
                    return
                }
                // Waiter was nil or already drained - slot reclaimed, continue
            }
        }

        /// Dequeue the next armed waiter without resuming it.
        ///
        /// This is used for reservation-based handoff where the caller wants to:
        /// 1. Dequeue the waiter
        /// 2. Set up the reservation state
        /// 3. Resume the waiter after reservation is committed
        ///
        /// Skips cancelled waiters (they're drained).
        /// Returns the waiter if found, nil if queue is empty or all waiters are cancelled.
        ///
        /// MUST be called on the actor executor.
        public mutating func dequeueNextArmed() -> Waiter? {
            while _count > 0 {
                let waiter = storage[head]
                storage[head] = nil
                head = (head + 1) % capacity
                _count -= 1

                if let waiter = waiter, waiter.isArmed && !waiter.isDrained {
                    // Found an armed, non-drained waiter
                    return waiter
                }
                // Waiter was nil, unarmed, or already drained - continue
            }
            return nil
        }

        /// Resume all waiters (cancelled or not).
        ///
        /// Used during shutdown to wake all waiting tasks.
        /// Cancelled waiters are drained - their tasks will observe cancellation after wake.
        ///
        /// MUST be called on the actor executor.
        public mutating func resumeAll() {
            while _count > 0 {
                if let waiter = storage[head], let result = waiter.takeForResume() {
                    result.continuation.resume()
                }
                storage[head] = nil
                head = (head + 1) % capacity
                _count -= 1
            }
        }
    }
}
