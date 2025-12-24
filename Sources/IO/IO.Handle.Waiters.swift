//
//  IO.Handle.Waiters.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 24/12/2025.
//

extension IO.Handle {
    /// FIFO ring buffer queue of tasks waiting for a handle.
    ///
    /// ## Thread Safety
    /// All access must be externally synchronized (actor-isolated or under lock).
    ///
    /// ## Invariants
    /// - All mutations must be externally synchronized
    /// - Ring buffer scan uses `_count` at entry; concurrent mutations would violate this
    ///
    /// ## Cancellation Pattern
    /// - `cancel(token:)` marks waiter as cancelled and returns its continuation
    /// - Caller MUST resume the continuation immediately (exactly-once semantics)
    /// - `resumeNext()` skips cancelled entries, reclaiming their slots
    ///
    /// ## Bounded Capacity
    /// Uses a fixed capacity ring buffer. If capacity is exhausted, `enqueue`
    /// returns false (caller should handle gracefully or fail).
    public struct Waiters {
        /// Default capacity for waiter queues.
        /// This is a per-handle limit, keeping memory bounded.
        public static let defaultCapacity: Int = 64

        private var storage: [Node?]
        private var head: Int = 0
        private var tail: Int = 0
        private var _count: Int = 0
        private let capacity: Int
        private var nextToken: UInt64 = 0

        public init(capacity: Int = Waiters.defaultCapacity) {
            self.capacity = max(capacity, 1)
            self.storage = [Node?](repeating: nil, count: self.capacity)
        }

        public var count: Int { _count }
        public var isEmpty: Bool { _count == 0 }
        public var isFull: Bool { _count >= capacity }

        public mutating func generateToken() -> UInt64 {
            let token = nextToken
            nextToken += 1
            return token
        }

        /// Enqueue a waiter. Returns false if queue is full.
        public mutating func enqueue(token: UInt64, continuation: CheckedContinuation<Void, Never>) -> Bool {
            guard _count < capacity else { return false }
            storage[tail] = Node(token: token, continuation: continuation)
            tail = (tail + 1) % capacity
            _count += 1
            return true
        }

        /// Mark a waiter as cancelled by token.
        /// Returns the continuation if found and not already cancelled.
        ///
        /// O(n) scan - acceptable with bounded capacity.
        /// Caller MUST resume the returned continuation immediately.
        public mutating func cancel(token: UInt64) -> CheckedContinuation<Void, Never>? {
            var idx = head
            var remaining = _count
            while remaining > 0 {
                if var node = storage[idx], node.token == token, !node.isCancelled {
                    node.isCancelled = true
                    storage[idx] = node
                    return node.continuation
                }
                idx = (idx + 1) % capacity
                remaining -= 1
            }
            return nil
        }

        /// Resume exactly one non-cancelled waiter.
        /// Skips cancelled waiters (they were already resumed with cancellation).
        /// Reclaims cancelled slots to recover capacity.
        public mutating func resumeNext() {
            while _count > 0 {
                let node = storage[head]
                storage[head] = nil
                head = (head + 1) % capacity
                _count -= 1

                if let node = node, !node.isCancelled {
                    node.continuation.resume()
                    return
                }
                // Cancelled or nil - slot reclaimed, continue
            }
        }

        /// Resume all non-cancelled waiters.
        public mutating func resumeAll() {
            while _count > 0 {
                if let node = storage[head], !node.isCancelled {
                    node.continuation.resume()
                }
                storage[head] = nil
                head = (head + 1) % capacity
                _count -= 1
            }
        }
    }
}
