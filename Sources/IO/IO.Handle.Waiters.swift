//
//  IO.Handle.Waiters.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 24/12/2025.
//

extension IO.Handle {
    /// FIFO queue of tasks waiting for a handle.
    ///
    /// ## Thread Safety
    /// Uses internal synchronization (`IO._Lock`) to ensure safe access from:
    /// - Actor-isolated pool methods (enqueue, drain, resume)
    /// - @Sendable closures (withCheckedContinuation body)
    /// - Cancellation handlers (onCancel)
    ///
    /// This is required because @Sendable closures may access the waiter storage
    /// outside the actor's serialization domain.
    ///
    /// ## Reference Semantics
    /// Copies of this struct share the same underlying storage. This is intentional:
    /// the waiter queue must be accessible from multiple contexts (actor methods,
    /// cancellation handlers) while referring to the same queue.
    ///
    /// ## Bounded Capacity
    /// Uses a fixed capacity ring buffer. If capacity is exhausted, `enqueue`
    /// returns `.rejected(.full)`.
    ///
    /// ## Resumption Invariant
    /// Continuations are NEVER resumed while holding the lock. All methods that
    /// may resume a continuation either:
    /// - Return the continuation for the caller to resume (cancel, closeAndDrain)
    /// - Resume after releasing the lock (enqueue on rejection, resumeNext)
    struct Waiters: Sendable {
        /// Default capacity for waiter queues.
        static let defaultCapacity: Int = 64

        /// Result of attempting to enqueue a waiter.
        ///
        /// ## Caller Responsibilities
        /// - `.stored`: Continuation is stored and will be resumed later. Do nothing.
        /// - `.rejected(...)`: Continuation was NOT stored. Caller MUST resume it.
        enum EnqueueResult: Sendable, Equatable {
            /// Successfully stored - waiter will be resumed later by `resumeNext()`.
            case stored
            /// Rejected - caller MUST resume the continuation immediately.
            case rejected(Rejection)

            enum Rejection: Sendable, Equatable {
                /// Queue is closed (shutdown/destroy in progress).
                case closed
                /// Queue capacity exhausted.
                case full
            }
        }

        /// Synchronized storage. This is the single point of synchronization.
        private let lock: IO._Lock<State>

        init(capacity: Int = Waiters.defaultCapacity) {
            self.lock = IO._Lock(State(capacity: max(capacity, 1)))
        }

        /// Generates a unique token for waiter identification.
        ///
        /// Tokens are used to cancel specific waiters. Each token is unique
        /// within this queue's lifetime (with wraparound at UInt64.max).
        func generateToken() -> UInt64 {
            lock.withLock { $0.generateToken() }
        }

        /// Attempts to enqueue a waiter.
        ///
        /// ## Critical Invariants
        /// 1. On `.stored`: continuation is stored and will be resumed by `resumeNext()`.
        /// 2. On `.rejected(...)`: continuation is NOT stored. Caller MUST resume it.
        /// 3. Resumption happens AFTER releasing the lock to prevent reentrancy deadlock.
        ///
        /// - Parameters:
        ///   - token: Unique token from `generateToken()` for cancellation.
        ///   - continuation: The continuation to enqueue or reject.
        /// - Returns: Result indicating whether the continuation was stored or rejected.
        func enqueue(
            token: UInt64,
            continuation: CheckedContinuation<Void, Never>
        ) -> EnqueueResult {
            // Decide under lock, resume after releasing.
            let result: EnqueueResult = lock.withLock { state in
                if state.isClosed { return .rejected(.closed) }
                guard state.enqueue(token: token, continuation: continuation) else {
                    return .rejected(.full)
                }
                return .stored
            }

            // Resume outside the lock to prevent reentrancy deadlock.
            if case .rejected = result {
                continuation.resume()
            }

            return result
        }

        /// Closes the queue and drains all pending continuations.
        ///
        /// After calling this method:
        /// - `enqueue` will return `.rejected(.closed)`
        /// - The returned continuations MUST be resumed by the caller
        ///
        /// Idempotent - calling on an already-closed queue returns empty array.
        ///
        /// - Returns: All pending continuations that need to be resumed.
        func closeAndDrain() -> [CheckedContinuation<Void, Never>] {
            lock.withLock { state in
                guard !state.isClosed else { return [] }
                state.isClosed = true
                return state.drainAll()
            }
        }

        /// Cancels a waiter by token, returning its continuation if found.
        ///
        /// Caller MUST resume the returned continuation immediately.
        ///
        /// Idempotent: returns nil if token not found (already cancelled,
        /// already drained, or never enqueued).
        ///
        /// Callable from @Sendable contexts (cancellation handlers).
        func cancel(token: UInt64) -> CheckedContinuation<Void, Never>? {
            lock.withLock { state in
                state.cancel(token: token)
            }
        }

        /// Resumes exactly one pending waiter.
        ///
        /// Skips cancelled waiters (those whose continuation was already taken).
        /// Called after a handle is checked back in.
        func resumeNext() {
            let continuation: CheckedContinuation<Void, Never>? = lock.withLock { state in
                state.takeNext()
            }
            continuation?.resume()
        }
    }
}

// MARK: - State

extension IO.Handle.Waiters {
    /// Mutable state protected by the lock.
    ///
    /// This type never calls `resume()` on any continuation. It only stores,
    /// retrieves, and removes continuations. All resumption happens in the
    /// outer `Waiters` methods after the lock is released.
    ///
    /// Ring buffer queue where each slot contains a token and optional continuation.
    /// Continuation is nil after being taken (via cancel or takeNext).
    struct State: Sendable {
        private var nodes: [Node?]
        private var head: Int = 0
        private var tail: Int = 0
        private var count: Int = 0
        private let capacity: Int
        private var nextToken: UInt64 = 0
        var isClosed: Bool = false

        init(capacity: Int) {
            self.capacity = capacity
            self.nodes = [Node?](repeating: nil, count: capacity)
        }

        var isFull: Bool { count >= capacity }

        mutating func generateToken() -> UInt64 {
            let token = nextToken
            nextToken &+= 1  // Wrapping add
            return token
        }

        /// Attempts to enqueue a waiter.
        ///
        /// - Returns: `true` if stored, `false` if queue is full.
        mutating func enqueue(token: UInt64, continuation: CheckedContinuation<Void, Never>) -> Bool {
            guard count < capacity else { return false }
            nodes[tail] = Node(token: token, continuation: continuation)
            tail = (tail + 1) % capacity
            count += 1
            return true
        }

        mutating func cancel(token: UInt64) -> CheckedContinuation<Void, Never>? {
            var idx = head
            var remaining = count
            while remaining > 0 {
                if var node = nodes[idx], node.token == token, node.continuation != nil {
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
            while count > 0 {
                let storedNode = nodes[head]
                nodes[head] = nil
                head = (head + 1) % capacity
                count -= 1

                if var node = storedNode, let c = node.takeContinuation() {
                    return c
                }
            }
            return nil
        }

        mutating func drainAll() -> [CheckedContinuation<Void, Never>] {
            var continuations: [CheckedContinuation<Void, Never>] = []
            while count > 0 {
                if var node = nodes[head], let c = node.takeContinuation() {
                    continuations.append(c)
                }
                nodes[head] = nil
                head = (head + 1) % capacity
                count -= 1
            }
            return continuations
        }
    }

    /// A single waiter in the queue.
    ///
    /// ## Exactly-Once Resumption
    /// Continuation is nil'd out when consumed via `takeContinuation()`.
    /// This makes double-resume structurally impossible:
    /// - `takeContinuation()` returns and nils the continuation atomically
    /// - Subsequent calls return nil
    struct Node: Sendable {
        let token: UInt64
        /// The continuation, or nil if already consumed (resumed or cancelled).
        var continuation: CheckedContinuation<Void, Never>?

        init(token: UInt64, continuation: CheckedContinuation<Void, Never>) {
            self.token = token
            self.continuation = continuation
        }

        /// Takes the continuation, returning it and setting to nil.
        ///
        /// Returns nil if already taken. Ensures exactly-once consumption.
        mutating func takeContinuation() -> CheckedContinuation<Void, Never>? {
            let c = continuation
            continuation = nil
            return c
        }
    }
}
