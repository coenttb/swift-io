//
//  IO.Handle.Waiters.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 24/12/2025.
//

import Synchronization

extension IO.Handle {
    /// FIFO ring buffer queue of tasks waiting for a handle.
    ///
    /// ## Thread Safety
    /// Uses internal synchronization (Mutex) to ensure safe access from:
    /// - Actor-isolated pool methods (enqueue, drain, resume)
    /// - @Sendable closures (withCheckedContinuation body)
    /// - Cancellation handlers (onCancel)
    ///
    /// This is required because @Sendable closures may access the waiter storage
    /// outside the actor's serialization domain.
    ///
    /// ## Bounded Capacity
    /// Uses a fixed capacity ring buffer. If capacity is exhausted, `enqueue`
    /// returns queueFull and resumes the continuation immediately.
    struct Waiters: @unchecked Sendable {
        /// Default capacity for waiter queues.
        static let defaultCapacity: Int = 64

        /// Result of attempting to enqueue a waiter.
        enum EnqueueResult: Sendable {
            /// Successfully enqueued - waiter will be resumed later.
            case enqueued
            /// Queue is full - continuation was resumed immediately.
            case queueFull
            /// Queue is closed - continuation was resumed immediately.
            case closedAndResumed
        }

        /// Internal synchronized storage.
        private let storage: Storage

        init(capacity: Int = Waiters.defaultCapacity) {
            self.storage = Storage(capacity: max(capacity, 1))
        }

        var count: Int { storage.withLock { $0.count } }
        var isEmpty: Bool { storage.withLock { $0.isEmpty } }
        var isFull: Bool { storage.withLock { $0.isFull } }
        var isClosed: Bool { storage.withLock { $0.isClosed } }

        func generateToken() -> UInt64 {
            storage.withLock { $0.generateToken() }
        }

        /// Enqueues a waiter, or resumes immediately if the queue is closed or full.
        ///
        /// This is the safe API for use inside `withCheckedContinuation` closures
        /// and is callable from @Sendable contexts.
        ///
        /// ## Critical Invariants
        /// 1. This method ALWAYS either stores the continuation (for later resumption)
        ///    or resumes it immediately. There is no path that drops the continuation.
        /// 2. Continuations are resumed AFTER releasing the lock to prevent deadlock.
        ///    Resuming under lock can execute arbitrary user code that may re-enter
        ///    the pool, trigger cancellation handlers, or call shutdown.
        ///
        /// - Parameters:
        ///   - token: The waiter's cancellation token.
        ///   - continuation: The continuation to enqueue or resume.
        /// - Returns: The result indicating what action was taken.
        func enqueueOrResumeIfClosed(
            token: UInt64,
            continuation: CheckedContinuation<Void, Never>
        ) -> EnqueueResult {
            // Decide under lock, resume after releasing.
            let result: EnqueueResult = storage.withLock { state in
                if state.isClosed { return .closedAndResumed }
                if state.isFull { return .queueFull }
                state.enqueue(token: token, continuation: continuation)
                return .enqueued
            }

            // Resume outside the lock to prevent reentrancy deadlock.
            switch result {
            case .enqueued:
                break
            case .queueFull, .closedAndResumed:
                continuation.resume()
            }

            return result
        }

        /// Closes the queue and drains all pending continuations.
        ///
        /// After calling this method:
        /// - `isClosed` returns true
        /// - `enqueueOrResumeIfClosed` will resume immediately
        /// - The returned continuations must be resumed by the caller
        ///
        /// Idempotent - calling on an already-closed queue returns empty array.
        ///
        /// - Returns: All pending continuations that need to be resumed.
        func closeAndDrain() -> [CheckedContinuation<Void, Never>] {
            storage.withLock { state in
                guard !state.isClosed else { return [] }
                state.isClosed = true
                return state.drainAll()
            }
        }

        /// Marks a waiter as cancelled by token, returning its continuation.
        ///
        /// Caller must resume the returned continuation immediately.
        ///
        /// This method is idempotent: if the token is not found (already cancelled,
        /// already drained, or never enqueued), returns nil without side effects.
        ///
        /// Callable from @Sendable contexts (cancellation handlers).
        func cancel(token: UInt64) -> CheckedContinuation<Void, Never>? {
            storage.withLock { state in
                state.cancel(token: token)
            }
        }

        /// Resumes exactly one non-cancelled waiter.
        ///
        /// Skips cancelled waiters and reclaims their slots.
        func resumeNext() {
            let continuation: CheckedContinuation<Void, Never>? = storage.withLock { state in
                state.takeNext()
            }
            continuation?.resume()
        }

        /// Resumes all non-cancelled waiters.
        func resumeAll() {
            let continuations: [CheckedContinuation<Void, Never>] = storage.withLock { state in
                state.drainAll()
            }
            for c in continuations {
                c.resume()
            }
        }
    }
}

// MARK: - Internal Storage

extension IO.Handle.Waiters {
    /// Synchronized storage for waiter queue.
    ///
    /// Uses Mutex from Swift Synchronization for thread-safe access.
    private final class Storage: @unchecked Sendable {
        private let mutex: Mutex<State>

        init(capacity: Int) {
            self.mutex = Mutex(State(capacity: capacity))
        }

        func withLock<T>(_ body: (inout State) -> T) -> T {
            mutex.withLock { body(&$0) }
        }
    }

    /// Mutable state protected by the mutex.
    struct State {
        private var nodes: [Node?]
        private var head: Int = 0
        private var tail: Int = 0
        private var _count: Int = 0
        private let capacity: Int
        private var nextToken: UInt64 = 0
        var isClosed: Bool = false

        init(capacity: Int) {
            self.capacity = capacity
            self.nodes = [Node?](repeating: nil, count: capacity)
        }

        var count: Int { _count }
        var isEmpty: Bool { _count == 0 }
        var isFull: Bool { _count >= capacity }

        mutating func generateToken() -> UInt64 {
            let token = nextToken
            nextToken += 1
            return token
        }

        mutating func enqueue(token: UInt64, continuation: CheckedContinuation<Void, Never>) {
            precondition(_count < capacity, "Queue is full")
            nodes[tail] = Node(token: token, continuation: continuation)
            tail = (tail + 1) % capacity
            _count += 1
        }

        mutating func cancel(token: UInt64) -> CheckedContinuation<Void, Never>? {
            var idx = head
            var remaining = _count
            while remaining > 0 {
                if var node = nodes[idx], node.token == token, !node.isCancelled {
                    node.isCancelled = true
                    let continuation = node.takeContinuation()
                    nodes[idx] = node
                    return continuation
                }
                idx = (idx + 1) % capacity
                remaining -= 1
            }
            return nil
        }

        mutating func takeNext() -> CheckedContinuation<Void, Never>? {
            while _count > 0 {
                let storedNode = nodes[head]
                nodes[head] = nil
                head = (head + 1) % capacity
                _count -= 1

                if var node = storedNode, !node.isCancelled {
                    return node.takeContinuation()
                }
            }
            return nil
        }

        mutating func drainAll() -> [CheckedContinuation<Void, Never>] {
            var continuations: [CheckedContinuation<Void, Never>] = []
            while _count > 0 {
                if var node = nodes[head], !node.isCancelled {
                    if let c = node.takeContinuation() {
                        continuations.append(c)
                    }
                }
                nodes[head] = nil
                head = (head + 1) % capacity
                _count -= 1
            }
            return continuations
        }
    }
}
