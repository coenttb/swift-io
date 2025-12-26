//
//  IO.Handle.Waiters.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 24/12/2025.
//

extension IO.Handle {
    /// FIFO queue of tasks waiting for a handle.
    ///
    /// This type is designed for use with:
    /// - actor-isolated pool methods (register, resumeNext, closeAndDrain)
    /// - @Sendable contexts (withCheckedContinuation body)
    /// - cancellation handlers (onCancel)
    ///
    /// ## Design
    /// The waiter lifecycle is two-phase:
    /// 1. `register()` creates a cancellable identity (`Ticket`) that is immediately observable to cancellation.
    /// 2. `arm(ticket, continuation)` attaches the continuation and makes it eligible for FIFO resumption.
    ///
    /// This eliminates the TOCTOU race where `onCancel` can run before the continuation is enqueued.
    ///
    /// ## Invariants
    /// 1. **Exactly-once consumption:** Every Ticket transitions to "absent from pending" exactly once.
    /// 2. **No orphaning:** A continuation exists only in `.armed` and every removal yields a continuation to resume.
    /// 3. **Cancellation visibility:** After `register()` returns, any `cancel(ticket)` observes it.
    /// 4. **Boundedness:** `pending.count <= capacity` always.
    /// 5. **Resume outside lock:** All methods return continuations, never resume internally.
    struct Waiters: Sendable {
        /// Default capacity for waiter queues.
        static let defaultCapacity: Int = 64

        /// Opaque waiter identity. Only created by `register()`.
        struct Ticket: Sendable, Equatable {
            fileprivate let id: UInt64
        }

        enum RegisterResult: Sendable, Equatable {
            case registered(Ticket)
            case rejected(Rejection)

            enum Rejection: Sendable, Equatable {
                case closed
                case full
            }
        }

        enum ArmResult: Sendable, Equatable {
            case stored
            case resumeNow(Reason)

            enum Reason: Sendable, Equatable {
                case closed
                case cancelled
                case handleAvailable
            }
        }

        /// Synchronized storage. This is the single point of synchronization.
        private let lock: IO._Lock<State>

        init(capacity: Int = Waiters.defaultCapacity) {
            self.lock = IO._Lock(State(capacity: max(capacity, 1)))
        }

        /// Registers a waiter identity.
        ///
        /// After this returns `.registered(ticket)`, cancellation MUST be able to observe this ticket.
        ///
        /// Capacity is enforced at registration time (bounded by `capacity`).
        func register() -> RegisterResult {
            lock.withLock { state in
                state.register()
            }
        }

        /// Arms a registered ticket with its continuation.
        ///
        /// - Returns:
        ///   - `.stored`: continuation is now eligible for FIFO resumption (via `resumeNext` or `closeAndDrain`).
        ///   - `.resumeNow(.cancelled/.closed)`: continuation MUST be resumed immediately by the caller.
        ///
        /// ## Important
        /// This method never calls `resume()`. It only returns whether the caller must resume now.
        func arm(_ ticket: Ticket, _ continuation: CheckedContinuation<Void, Never>) -> ArmResult {
            lock.withLock { state in
                state.arm(ticket, continuation)
            }
        }

        /// Abandons a registered-but-unarmed ticket.
        ///
        /// This is for early-exit paths where the caller decides not to wait after registering.
        /// It is a no-op if the ticket is already consumed.
        ///
        /// ## Programmer Error
        /// Calling `abandon` on an armed ticket is an invariant violation and triggers `preconditionFailure`.
        func abandon(_ ticket: Ticket) {
            lock.withLock { state in
                state.abandon(ticket)
            }
        }

        /// Cancels a ticket.
        ///
        /// - Returns: the continuation if the ticket was armed at the time of cancellation.
        ///
        /// Caller MUST resume the returned continuation immediately (if non-nil).
        ///
        /// Idempotent: returns nil if already cancelled/consumed/drained or if cancellation happened pre-arm.
        func cancel(_ ticket: Ticket) -> CheckedContinuation<Void, Never>? {
            lock.withLock { state in
                state.cancel(ticket)
            }
        }

        /// Dequeues the next armed waiter in FIFO order.
        ///
        /// - Returns: the continuation to resume, or nil if no armed waiters remain.
        ///
        /// Skips tombstones (tickets that were cancelled after being queued).
        ///
        /// ## Note
        /// This method is for **fairness handoffs** (cancellation, destroy races).
        /// For check-in wakeups, use `signalHandleAvailable()` instead.
        func resumeNext() -> CheckedContinuation<Void, Never>? {
            lock.withLock { state in
                state.takeNext()
            }
        }

        /// Signals that a handle has become available.
        ///
        /// This method implements the **availability permit** semantics:
        /// - If an armed waiter exists: return its continuation (permit consumed immediately)
        /// - Otherwise: record the availability permit for a future arm() call
        ///
        /// This ensures a handle becoming available produces a durable signal
        /// consumed exactly once, regardless of whether a waiter is already armed.
        ///
        /// ## Usage
        /// Call this method **only** when a handle is checked in and becomes present.
        /// For fairness handoffs (cancellation, destroy), use `resumeNext()` instead.
        func signalHandleAvailable() -> CheckedContinuation<Void, Never>? {
            lock.withLock { state in
                state.signalHandleAvailable()
            }
        }

        /// Closes the queue and drains all pending armed continuations.
        ///
        /// After calling this method:
        /// - `register` returns `.rejected(.closed)`
        /// - `arm` returns `.resumeNow(.closed)`
        ///
        /// Idempotent: calling on an already-closed queue returns an empty array.
        ///
        /// - Returns: All armed continuations that need to be resumed by the caller.
        func closeAndDrain() -> [CheckedContinuation<Void, Never>] {
            lock.withLock { state in
                state.closeAndDrain()
            }
        }

        // MARK: - Debug

        /// Debug snapshot for diagnosing hangs.
        struct DebugSnapshot: Sendable, CustomStringConvertible {
            let isClosed: Bool
            let handleAvailable: Bool
            let pendingCount: Int
            let armedCount: Int
            let fifoCount: Int

            var description: String {
                "Waiters(closed=\(isClosed), permit=\(handleAvailable), pending=\(pendingCount), armed=\(armedCount), fifo=\(fifoCount))"
            }
        }

        /// Returns a debug snapshot of the current waiter state.
        func debugSnapshot() -> DebugSnapshot {
            lock.withLock { state in
                state.debugSnapshot()
            }
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
    struct State: Sendable {
        private enum Pending: Sendable {
            case registering(cancelled: Bool)
            case armed(CheckedContinuation<Void, Never>)
        }

        private var isClosed: Bool = false
        private var nextID: UInt64 = 1

        /// Availability permit: true if a handle is available and unclaimed.
        /// Set by `signalHandleAvailable()` when no armed waiter exists.
        /// Consumed by `arm()` when a waiter arms and the permit is set.
        private var handleAvailable: Bool = false

        /// Bounded by `capacity`. Represents all live waiter identities.
        private var pending: [UInt64: Pending] = [:]

        /// FIFO order of tickets that were armed. May contain stale tombstones.
        private var fifo: [UInt64?]
        private var head: Int = 0
        private var tail: Int = 0
        private var fifoCount: Int = 0

        private let capacity: Int

        init(capacity: Int) {
            self.capacity = max(capacity, 1)
            self.fifo = Array(repeating: nil, count: self.capacity)
        }

        mutating func register() -> RegisterResult {
            if isClosed { return .rejected(.closed) }
            if pending.count >= capacity { return .rejected(.full) }

            let id = nextID
            nextID &+= 1

            pending[id] = .registering(cancelled: false)
            return .registered(.init(id: id))
        }

        mutating func arm(_ ticket: Ticket, _ continuation: CheckedContinuation<Void, Never>) -> ArmResult {
            if isClosed {
                // Consume the ticket if present (best-effort), then force immediate resume.
                pending.removeValue(forKey: ticket.id)
                return .resumeNow(.closed)
            }

            guard let current = pending[ticket.id] else {
                preconditionFailure("Waiters.arm called with an unknown or already-consumed ticket")
            }

            switch current {
            case .registering(cancelled: true):
                pending.removeValue(forKey: ticket.id)
                return .resumeNow(.cancelled)

            case .registering(cancelled: false):
                // Check availability permit before storing
                if handleAvailable {
                    // Consume permit and resume immediately
                    handleAvailable = false
                    pending.removeValue(forKey: ticket.id)
                    return .resumeNow(.handleAvailable)
                }
                pending[ticket.id] = .armed(continuation)
                fifoEnqueue(ticket.id)
                return .stored

            case .armed:
                preconditionFailure("Waiters.arm called more than once for the same ticket")
            }
        }

        mutating func abandon(_ ticket: Ticket) {
            guard let current = pending[ticket.id] else { return }

            switch current {
            case .registering:
                pending.removeValue(forKey: ticket.id)

            case .armed:
                preconditionFailure("Waiters.abandon called for an armed ticket")
            }
        }

        mutating func cancel(_ ticket: Ticket) -> CheckedContinuation<Void, Never>? {
            guard let current = pending[ticket.id] else { return nil }

            switch current {
            case .registering(cancelled: false):
                pending[ticket.id] = .registering(cancelled: true)
                return nil

            case .registering(cancelled: true):
                return nil

            case .armed(let c):
                pending.removeValue(forKey: ticket.id)
                return c
            }
        }

        mutating func takeNext() -> CheckedContinuation<Void, Never>? {
            while fifoCount > 0 {
                let storedID = fifo[head]
                fifo[head] = nil
                head = (head + 1) % capacity
                fifoCount -= 1

                guard let id = storedID else { continue }
                guard let entry = pending[id] else { continue }

                switch entry {
                case .armed(let c):
                    pending.removeValue(forKey: id)
                    return c

                case .registering:
                    // Should not happen: FIFO contains only armed IDs.
                    // Treat as tombstone to avoid hangs.
                    continue
                }
            }
            return nil
        }

        /// Signals that a handle has become available.
        ///
        /// Implements availability permit semantics:
        /// - If an armed waiter exists: return its continuation (permit consumed immediately)
        /// - Otherwise: record the availability permit for a future arm() call
        mutating func signalHandleAvailable() -> CheckedContinuation<Void, Never>? {
            // First, try to find an armed waiter
            if let continuation = takeNext() {
                // Permit consumed immediately by this waiter
                return continuation
            }
            // No armed waiter - record the permit for a future arm()
            handleAvailable = true
            return nil
        }

        mutating func closeAndDrain() -> [CheckedContinuation<Void, Never>] {
            guard !isClosed else { return [] }
            isClosed = true

            var continuations: [CheckedContinuation<Void, Never>] = []
            continuations.reserveCapacity(fifoCount)

            // Drain all armed continuations from `pending` (source of truth).
            for (_, entry) in pending {
                if case .armed(let c) = entry {
                    continuations.append(c)
                }
                // registering tickets are simply discarded; future arm() will resumeNow(.closed)
            }

            pending.removeAll(keepingCapacity: true)
            fifo = Array(repeating: nil, count: capacity)
            head = 0
            tail = 0
            fifoCount = 0
            handleAvailable = false  // Clear permit on close

            return continuations
        }

        func debugSnapshot() -> IO.Handle.Waiters.DebugSnapshot {
            var armedCount = 0
            for (_, entry) in pending {
                if case .armed = entry {
                    armedCount += 1
                }
            }
            return IO.Handle.Waiters.DebugSnapshot(
                isClosed: isClosed,
                handleAvailable: handleAvailable,
                pendingCount: pending.count,
                armedCount: armedCount,
                fifoCount: fifoCount
            )
        }

        private mutating func fifoEnqueue(_ id: UInt64) {
            // FIFO capacity is bounded by overall `capacity` and `pending.count`.
            // We defensively ensure space exists.
            if fifoCount >= capacity {
                preconditionFailure("Waiters FIFO overflow: invariant violation")
            }

            fifo[tail] = id
            tail = (tail + 1) % capacity
            fifoCount += 1
        }
    }
}
