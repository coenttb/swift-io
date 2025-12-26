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

        /// Namespace for ticket-related types.
        ///
        /// The ticket lifecycle separates identity from capability:
        /// - `ID`: Copyable identity used in internal data structures
        /// - `Token<P>`: Capability to transition (arm or cancel) - move-only, phantom-typed
        /// - `StoredToken<P>`: Copyable storage handle that produces move-only Token
        /// - `Cell`: Sendable reference cell allowing exactly-once token extraction
        struct Ticket {
            /// Phantom types representing ticket lifecycle phases.
            ///
            /// Currently only `Registering` is used - after consumption, the token is gone.
            /// This typestate documents that a token came from `register()` and is ready
            /// for either `arm()` or `cancel()`.
            enum Phase {
                /// The ticket has been registered but not yet armed or cancelled.
                enum Registering {}
            }

            /// Copyable waiter identity for internal bookkeeping.
            struct ID: Sendable, Hashable {
                fileprivate let raw: UInt64
            }

            /// Shared box enforcing exactly-once consumption across all references.
            ///
            /// This box is needed because:
            /// - We need shared, thread-safe exactly-once state that persists across
            ///   storage/transfer and copies of storage handles (StoredToken).
            /// - Swift cannot yet express an affine capability without either a box
            ///   or language-level linear types.
            fileprivate final class Box: @unchecked Sendable {
                private let lock: IO._Lock<Bool>

                init() {
                    self.lock = IO._Lock(false)
                }

                /// Returns true if this is the first consumption, false otherwise.
                func consume() -> Bool {
                    lock.withLock { consumed in
                        if consumed { return false }
                        consumed = true
                        return true
                    }
                }
            }

            /// Copyable storage handle for Cell to hold behind IO._Lock.
            ///
            /// This is copyable because it only holds references (Box) and an ID.
            /// The Box enforces exactly-once consumption across copies.
            /// The move-only property is preserved at the API boundary where
            /// `move()` extracts a `Token<P>`.
            struct StoredToken<P>: Sendable {
                fileprivate let id: ID
                fileprivate let box: Box

                fileprivate init(id: ID) {
                    self.id = id
                    self.box = Box()
                }

                /// Converts this storage handle into a move-only Token.
                fileprivate consuming func move() -> Token<P> {
                    Token(id: id, box: box)
                }
            }

            /// Capability to arm or cancel a registered ticket.
            ///
            /// This token is move-only and affine: it can only be consumed once
            /// (for arm or cancel). The phantom type `P` indicates the token's phase.
            ///
            /// ## Usage
            /// ```swift
            /// switch cell.take() {
            /// case .token(let token):
            ///     waiters.arm(token, continuation)  // OR
            ///     waiters.cancel(token)
            /// case .alreadyTaken:
            ///     // handle race
            /// }
            /// ```
            struct Token<P>: ~Copyable, Sendable {
                fileprivate let id: ID
                private let box: Box

                fileprivate init(id: ID, box: Box) {
                    self.id = id
                    self.box = box
                }

                /// Consumes this token's capability, returning the ID if not already consumed.
                fileprivate consuming func consume() -> ID? {
                    box.consume() ? id : nil
                }
            }

            /// Namespace for take-related types.
            struct Take {
                /// Result of attempting to take the token from a cell.
                ///
                /// This sum type forces exhaustive handling of both cases,
                /// making it a compile error to accidentally delete the cancel-by-ID fallback.
                ///
                /// `~Copyable` because the `.token` case contains a move-only `Token`.
                enum Result: ~Copyable, Sendable {
                    case token(Token<Phase.Registering>)
                    case alreadyTaken
                }
            }

            /// Sendable reference cell allowing exactly-once token extraction.
            ///
            /// Both the normal path and `onCancel` handler can call `take()`;
            /// only one wins and gets the token.
            final class Cell: @unchecked Sendable {
                /// The ticket identity (always valid, for logging/debugging).
                let id: ID

                private let lock: IO._Lock<StoredToken<Phase.Registering>?>

                fileprivate init(id: ID, storedToken: StoredToken<Phase.Registering>) {
                    self.id = id
                    self.lock = IO._Lock(storedToken)
                }

                /// Extracts the token exactly once. Subsequent calls return `.alreadyTaken`.
                func take() -> Take.Result {
                    lock.withLock { stored in
                        guard let s = stored else { return .alreadyTaken }
                        stored = nil
                        return .token(s.move())
                    }
                }
            }
        }

        /// Namespace for register-related types.
        struct Register {
            /// Result of attempting to register a waiter.
            enum Result: Sendable {
                case registered(Ticket.Cell)
                case rejected(Rejection)

                enum Rejection: Sendable, Equatable {
                    case closed
                    case full
                }
            }
        }

        /// Namespace for arm-related types.
        struct Arm {
            /// Result of arming a ticket with its continuation.
            ///
            /// This enum is `~Copyable` because the `.resumeNow` case contains a `Resume.Token`.
            enum Result: ~Copyable, Sendable {
                /// Continuation is now stored and eligible for FIFO resumption.
                case stored
                /// Continuation must be resumed immediately with the given reason.
                case resumeNow(Resume.Token, Reason)

                enum Reason: Sendable, Equatable {
                    case closed
                    case cancelled      // Returned when cancellation removed ticket between token.take() and arm()
                    case handleAvailable
                }
            }
        }

        /// Namespace for set-based containers.
        struct Set {
            /// Tracks ticket IDs that are registered but not yet armed.
            ///
            /// This container implements consume-on-cancel semantics:
            /// - `insert`: adds a new registering ticket
            /// - `consumeForArm`: removes entry when transitioning to armed state
            /// - `consumeForCancel`: removes entry when cancellation wins the race
            ///
            /// With the cell pattern, exactly one of `consumeForArm` or `consumeForCancel`
            /// will be called for each inserted ticket.
            struct Registering: Sendable {
                private var present: Swift.Set<Ticket.ID>

                init() {
                    self.present = []
                }

                /// The number of registering tickets.
                var count: Int { present.count }

                /// Whether there are no registering tickets.
                var isEmpty: Bool { present.isEmpty }

                /// Inserts a new registering ticket.
                mutating func insert(_ id: Ticket.ID) {
                    let (inserted, _) = present.insert(id)
                    precondition(inserted, "Ticket.ID already registered")
                }

                /// Consumes a registering ticket for arming.
                /// Returns true if the ticket was present (normal path).
                /// Returns false if already consumed (shouldn't happen with cell pattern).
                @discardableResult
                mutating func consumeForArm(_ id: Ticket.ID) -> Bool {
                    present.remove(id) != nil
                }

                /// Consumes a registering ticket for cancellation.
                /// Returns true if the ticket was present and consumed.
                /// Returns false if already consumed (cancellation lost the race).
                @discardableResult
                mutating func consumeForCancel(_ id: Ticket.ID) -> Bool {
                    present.remove(id) != nil
                }

                /// Removes all entries, returning the count removed.
                @discardableResult
                mutating func removeAll() -> Int {
                    let count = present.count
                    present.removeAll(keepingCapacity: true)
                    return count
                }
            }
        }

        /// Namespace for queue-based containers.
        struct Queue {
            /// Unified FIFO queue of armed waiters with their continuations.
            ///
            /// This container enforces "armed implies enqueued" as a representation invariant:
            /// - A ticket is armed if and only if it has an entry in this queue
            /// - No separate tracking needed; the queue IS the source of truth
            ///
            /// ## Operations
            /// - `enqueue`: adds an armed waiter to the back
            /// - `dequeueNext`: removes and returns the front waiter's continuation
            /// - `remove`: removes a specific waiter (for cancellation)
            struct Armed: Sendable {
                /// Ordered array of (id, continuation) pairs. Uses optional to mark tombstones.
                private var entries: [(id: Ticket.ID, continuation: CheckedContinuation<Void, Never>)?]
                private var head: Int = 0
                private var tail: Int = 0
                private var liveCount: Int = 0
                private let capacity: Int

                /// Lookup for O(1) cancellation. Maps ID to index in entries array.
                private var indexByID: [Ticket.ID: Int]

                init(capacity: Int) {
                    self.capacity = max(capacity, 1)
                    self.entries = Array(repeating: nil, count: self.capacity)
                    self.indexByID = [:]
                    self.indexByID.reserveCapacity(self.capacity)
                }

                /// Whether the queue is empty.
                var isEmpty: Bool { liveCount == 0 }

                /// The number of armed waiters.
                var count: Int { liveCount }

                /// Enqueues an armed waiter.
                mutating func enqueue(id: Ticket.ID, continuation: CheckedContinuation<Void, Never>) {
                    precondition(liveCount < capacity, "Queue.Armed overflow")
                    precondition(indexByID[id] == nil, "Ticket.ID already armed")

                    entries[tail] = (id: id, continuation: continuation)
                    indexByID[id] = tail
                    tail = (tail + 1) % capacity
                    liveCount += 1
                }

                /// Dequeues the next armed waiter in FIFO order.
                /// Skips tombstones (entries removed by `remove`).
                mutating func dequeueNext() -> CheckedContinuation<Void, Never>? {
                    while head != tail || liveCount > 0 {
                        guard let entry = entries[head] else {
                            // Tombstone - skip
                            head = (head + 1) % capacity
                            continue
                        }

                        entries[head] = nil
                        indexByID.removeValue(forKey: entry.id)
                        head = (head + 1) % capacity
                        liveCount -= 1
                        return entry.continuation
                    }
                    return nil
                }

                /// Removes a specific armed waiter (for cancellation).
                /// Returns the continuation if found, nil otherwise.
                mutating func remove(id: Ticket.ID) -> CheckedContinuation<Void, Never>? {
                    guard let index = indexByID.removeValue(forKey: id) else {
                        return nil
                    }
                    guard let entry = entries[index] else {
                        // Already a tombstone (shouldn't happen)
                        return nil
                    }
                    entries[index] = nil  // Create tombstone
                    liveCount -= 1
                    return entry.continuation
                }

                /// Drains all armed waiters, returning their continuations.
                mutating func drainAll() -> [CheckedContinuation<Void, Never>] {
                    var result: [CheckedContinuation<Void, Never>] = []
                    result.reserveCapacity(liveCount)

                    for i in 0..<entries.count {
                        if let entry = entries[i] {
                            result.append(entry.continuation)
                            entries[i] = nil
                        }
                    }

                    indexByID.removeAll(keepingCapacity: true)
                    head = 0
                    tail = 0
                    liveCount = 0
                    return result
                }
            }
        }

        // Note: A move-only Permit type would be ideal here to enforce "consume at most once"
        // structurally. However, Swift's type system currently requires cascading ~Copyable
        // through State and synchronization layers. The bool approach works correctly with
        // the existing lock-based synchronization.
        //
        // Future: When Swift supports ~Copyable in more contexts, revisit this.

        /// Namespace for resumption-related types.
        struct Resume {
            /// Token representing the obligation to resume a continuation exactly once.
            ///
            /// This type ensures:
            /// - **Exactly-once resumption:** Must call `resume()` exactly once.
            /// - **Move-only semantics:** Token cannot be copied; must be consumed.
            /// - **No orphaning:** In debug builds, dropping without calling `resume()` triggers an assertion.
            ///
            /// ## Usage
            /// ```swift
            /// if let token = waiters.cancel(ticket) {
            ///     token.resume()
            /// }
            /// ```
            struct Token: ~Copyable, Sendable {
                private let box: Box

                fileprivate init(_ continuation: CheckedContinuation<Void, Never>) {
                    self.box = Box(continuation)
                }

                /// Resumes the underlying continuation, consuming the token.
                ///
                /// - Precondition: Token has not already been consumed.
                consuming func resume() {
                    box.resume()
                }

                /// Shared box holding the continuation.
                ///
                /// Still uses a box internally because ~Copyable structs with deinit
                /// have restrictions, and we need the debug-mode leak detection.
                private final class Box: @unchecked Sendable {
                    private let lock: IO._Lock<CheckedContinuation<Void, Never>?>

                    init(_ continuation: CheckedContinuation<Void, Never>) {
                        self.lock = IO._Lock(continuation)
                    }

                    func resume() {
                        let c: CheckedContinuation<Void, Never> = lock.withLock { stored in
                            guard let c = stored else {
                                preconditionFailure("Resume.Token already consumed")
                            }
                            stored = nil
                            return c
                        }
                        c.resume()
                    }

                    deinit {
                        #if DEBUG
                        let leaked = lock.withLock { $0 != nil }
                        assert(!leaked, "Resume.Token dropped without calling resume()")
                        #endif
                    }
                }
            }
        }

        /// Synchronized storage. This is the single point of synchronization.
        private let lock: IO._Lock<State>

        init(capacity: Int = Waiters.defaultCapacity) {
            self.lock = IO._Lock(State(capacity: max(capacity, 1)))
        }

        // MARK: - Single Execution Point

        /// Executes a single-resumption action, returning a Resume.Token if present.
        ///
        /// This is the **execution point** for state transitions that produce at most one continuation.
        /// Use for: cancel, resumeNext, signalHandleAvailable.
        ///
        /// - Precondition: Action is `.none` or `.resume` (never `.resumeMany`).
        @inline(__always)
        private static func executeSingle(_ action: Action) -> Resume.Token? {
            switch action {
            case .none:
                return nil
            case .resume(let c, _):
                return Resume.Token(c)
            case .resumeMany:
                preconditionFailure("executeSingle called with resumeMany action")
            }
        }

        /// Executes a multi-resumption action by directly resuming all continuations.
        ///
        /// This is the **execution point** for state transitions that may produce multiple continuations.
        /// Use for: closeAndDrain.
        ///
        /// This method resumes continuations directly rather than returning tokens because
        /// `Resume.Token` is `~Copyable` and cannot be stored in arrays.
        @inline(__always)
        private static func executeAndResumeAll(_ action: Action) {
            switch action {
            case .none:
                break
            case .resume(let c, _):
                c.resume()
            case .resumeMany(let cs, _):
                for c in cs { c.resume() }
            }
        }

        // MARK: - Adapter Methods

        /// Registers a waiter identity.
        ///
        /// After this returns `.registered(cell)`, both the normal path and `onCancel`
        /// can call `cell.take()` to race for the token.
        ///
        /// Capacity is enforced at registration time (bounded by `capacity`).
        func register() -> Register.Result {
            lock.withLock { state in
                state.register()
            }
        }

        /// Arms a registered ticket with its continuation.
        ///
        /// - Parameter token: The ticket token (consumed by this call).
        /// - Parameter continuation: The continuation to store.
        /// - Returns:
        ///   - `.stored`: continuation is now eligible for FIFO resumption.
        ///   - `.resumeNow(.closed/.handleAvailable)`: continuation MUST be resumed immediately.
        ///
        /// ## Important
        /// This method never calls `resume()`. It only returns whether the caller must resume now.
        ///
        /// - Precondition: Token has not already been consumed.
        func arm(_ token: consuming Ticket.Token<Ticket.Phase.Registering>, _ continuation: CheckedContinuation<Void, Never>) -> Arm.Result {
            guard let id = token.consume() else {
                preconditionFailure("Ticket.Token already consumed")
            }
            // State returns State.Arm.Action, convert to public Arm.Result outside lock
            let action = lock.withLock { state in
                state.arm(id, continuation)
            }
            switch action {
            case .stored:
                return .stored
            case .resume(let cont, let reason):
                // Convert internal Reason to public Arm.Result.Reason
                let publicReason: Arm.Result.Reason = switch reason {
                case .handleAvailable: .handleAvailable
                case .cancelled: .cancelled
                case .closed: .closed
                }
                return .resumeNow(Resume.Token(cont), publicReason)
            }
        }

        /// Abandons a registered-but-unarmed ticket.
        ///
        /// This is for early-exit paths where the caller decides not to wait after registering.
        /// Removes the registering entry from the state.
        ///
        /// - Parameter token: The ticket token (consumed by this call).
        ///
        /// - Precondition: Token has not already been consumed.
        func abandon(_ token: consuming Ticket.Token<Ticket.Phase.Registering>) {
            guard let id = token.consume() else {
                preconditionFailure("Ticket.Token already consumed")
            }
            lock.withLock { state in
                state.abandon(id)
            }
        }

        /// Cancels a ticket.
        ///
        /// - Parameter token: The ticket token (consumed by this call).
        /// - Returns: A `Resume.Token` if the ticket was armed at the time of cancellation.
        ///
        /// Caller MUST call `resume()` on the returned token immediately (if non-nil).
        ///
        /// With consume-on-cancel semantics, this removes the entry entirely.
        ///
        /// - Precondition: Token has not already been consumed.
        func cancel(_ token: consuming Ticket.Token<Ticket.Phase.Registering>) -> Resume.Token? {
            guard let id = token.consume() else {
                preconditionFailure("Ticket.Token already consumed")
            }
            let action = lock.withLock { state in state.cancel(id) }
            return Self.executeSingle(action)
        }

        /// Cancels a waiter by ID for eager capacity reclamation.
        ///
        /// Use this when the token has already been consumed by `arm()` but cancellation
        /// needs to eagerly remove the waiter from the armed queue.
        ///
        /// - Parameter id: The ticket ID to cancel.
        /// - Returns: A `Resume.Token` if the waiter was armed, nil if already consumed or not found.
        func cancel(_ id: Ticket.ID) -> Resume.Token? {
            let action = lock.withLock { state in state.cancel(id) }
            return Self.executeSingle(action)
        }

        /// Dequeues the next armed waiter in FIFO order.
        ///
        /// - Returns: A `Resume.Token` to resume, or nil if no armed waiters remain.
        ///
        /// Skips tombstones (tickets that were cancelled after being queued).
        ///
        /// ## Note
        /// This method is for **fairness handoffs** (cancellation, destroy races).
        /// For check-in wakeups, use `signalHandleAvailable()` instead.
        func resumeNext() -> Resume.Token? {
            let action = lock.withLock { state in state.takeNext() }
            return Self.executeSingle(action)
        }

        /// Signals that a handle has become available.
        ///
        /// This method implements the **availability permit** semantics:
        /// - If an armed waiter exists: return a `Resume.Token` (permit consumed immediately)
        /// - Otherwise: record the availability permit for a future arm() call
        ///
        /// This ensures a handle becoming available produces a durable signal
        /// consumed exactly once, regardless of whether a waiter is already armed.
        ///
        /// ## Usage
        /// Call this method **only** when a handle is checked in and becomes present.
        /// For fairness handoffs (cancellation, destroy), use `resumeNext()` instead.
        func signalHandleAvailable() -> Resume.Token? {
            let action = lock.withLock { state in state.signalHandleAvailable() }
            return Self.executeSingle(action)
        }

        /// Closes the queue and resumes all pending armed waiters.
        ///
        /// After calling this method:
        /// - `register` returns `.rejected(.closed)`
        /// - `arm` returns `.resumeNow(.closed)`
        ///
        /// All armed waiters are resumed immediately with `.closed` reason.
        ///
        /// Idempotent: calling on an already-closed queue is a no-op.
        func closeAndDrain() {
            let action = lock.withLock { state in state.closeAndDrain() }
            Self.executeAndResumeAll(action)
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
    /// Unified action type for all state transitions.
    ///
    /// Every State method returns an Action that is executed via `Waiters.execute(_:)`
    /// outside the lock. This single execution point enforces "resume outside lock"
    /// and makes adding new action types a compile-time change across all call sites.
    fileprivate enum Action: Sendable {
        case none
        case resume(CheckedContinuation<Void, Never>, Reason)
        case resumeMany([CheckedContinuation<Void, Never>], Reason)
    }

    /// Reason for a resumption action.
    ///
    /// This is Equatable for testability (unlike Action which contains continuations).
    fileprivate enum Reason: Sendable, Equatable {
        case handleAvailable
        case cancelled
        case closed
    }

    /// Mutable state protected by the lock.
    ///
    /// This type never calls `resume()` on any continuation. It only stores,
    /// retrieves, and removes continuations. All resumption happens in the
    /// outer `Waiters` methods after the lock is released.
    fileprivate struct State: Sendable {
        /// Namespace for arm-related internal types.
        struct Arm {
            /// Action for State.arm - can only resume one continuation (not many).
            enum Action: Sendable {
                case stored
                case resume(CheckedContinuation<Void, Never>, Reason)
            }
        }

        /// Lifecycle state of the waiter queue.
        ///
        /// Transitions: `.open` → `.closed` (one-way, irreversible)
        enum Lifecycle: Sendable, Equatable {
            case open
            case closed
        }

        /// Availability permit for handle check-in.
        ///
        /// When a handle becomes available and no armed waiter exists,
        /// the permit is recorded. A future `arm()` consumes it immediately.
        enum Permit: Sendable, Equatable {
            case available
            case unavailable
        }

        private var lifecycle: Lifecycle = .open
        private var nextID: UInt64 = 1

        /// Availability permit for handle check-in.
        /// Set by `signalHandleAvailable()` when no armed waiter exists.
        /// Consumed by `arm()` when a waiter arms and the permit is set.
        private var permit: Permit = .unavailable

        /// Tickets that are registered but not yet armed.
        private var registering: Set.Registering

        /// Armed waiters in FIFO order with their continuations.
        /// Invariant: "armed implies enqueued" - the queue IS the source of truth.
        private var armed: Queue.Armed

        private let capacity: Int

        /// Total number of live waiters (registering + armed).
        private var totalCount: Int { registering.count + armed.count }

        init(capacity: Int) {
            self.capacity = max(capacity, 1)
            self.registering = Set.Registering()
            self.armed = Queue.Armed(capacity: self.capacity)
        }

        // MARK: - Helper Methods

        /// Attempts to consume the availability permit.
        ///
        /// - Returns: `true` if the permit was available and is now consumed.
        private mutating func consumePermitIfAvailable() -> Bool {
            switch permit {
            case .available:
                permit = .unavailable
                return true
            case .unavailable:
                return false
            }
        }

        /// Records an availability permit.
        private mutating func recordPermit() {
            permit = .available
        }

        /// Whether the queue is closed.
        private var isClosed: Bool { lifecycle == .closed }

        mutating func register() -> Register.Result {
            if isClosed { return .rejected(.closed) }
            if totalCount >= capacity { return .rejected(.full) }

            let rawID = nextID
            nextID &+= 1

            // Create the ticket ID, stored token, and cell
            let id = Ticket.ID(raw: rawID)
            registering.insert(id)

            let storedToken = Ticket.StoredToken<Ticket.Phase.Registering>(id: id)
            let cell = Ticket.Cell(id: id, storedToken: storedToken)
            return .registered(cell)
        }

        mutating func arm(_ id: Ticket.ID, _ continuation: CheckedContinuation<Void, Never>) -> Arm.Action {
            if isClosed {
                // Consume the ticket if present (best-effort), then force immediate resume.
                registering.consumeForArm(id)
                return .resume(continuation, .closed)
            }

            // Consume from registering - if missing, cancellation already removed it
            guard registering.consumeForArm(id) else {
                // Cancellation removed the ticket between token.take() and arm()
                return .resume(continuation, .cancelled)
            }

            // Check availability permit before storing
            if consumePermitIfAvailable() {
                return .resume(continuation, .handleAvailable)
            }

            // Enqueue to armed queue
            armed.enqueue(id: id, continuation: continuation)
            return .stored
        }

        mutating func abandon(_ id: Ticket.ID) {
            // Consume from registering - no-op if already consumed
            registering.consumeForCancel(id)
        }

        mutating func cancel(_ id: Ticket.ID) -> Action {
            // First, try to consume from registering
            if registering.consumeForCancel(id) {
                // Was in registering state - no continuation to return
                return .none
            }

            // Not in registering - try to remove from armed queue
            if let continuation = armed.remove(id: id) {
                return .resume(continuation, .cancelled)
            }
            return .none
        }

        mutating func takeNext() -> Action {
            if let continuation = armed.dequeueNext() {
                return .resume(continuation, .handleAvailable)
            }
            return .none
        }

        /// Signals that a handle has become available.
        ///
        /// Implements availability permit semantics:
        /// - If an armed waiter exists: return its continuation (permit consumed immediately)
        /// - Otherwise: record the availability permit for a future arm() call
        mutating func signalHandleAvailable() -> Action {
            // First, try to find an armed waiter
            if let continuation = armed.dequeueNext() {
                // Permit consumed immediately by this waiter
                return .resume(continuation, .handleAvailable)
            }
            // No armed waiter - record the permit for a future arm()
            recordPermit()
            return .none
        }

        mutating func closeAndDrain() -> Action {
            guard lifecycle == .open else { return .none }
            lifecycle = .closed

            // Drain all armed continuations
            let continuations = armed.drainAll()

            // Clear registering (those waiters will see .closed when arm() is called,
            // but with cell pattern they may never call arm() - that's OK)
            registering.removeAll()

            permit = .unavailable  // Clear permit on close

            if continuations.isEmpty {
                return .none
            }
            return .resumeMany(continuations, .closed)
        }

        func debugSnapshot() -> IO.Handle.Waiters.DebugSnapshot {
            IO.Handle.Waiters.DebugSnapshot(
                isClosed: lifecycle == .closed,
                handleAvailable: permit == .available,
                pendingCount: totalCount,
                armedCount: armed.count,
                fifoCount: armed.count  // fifo and armed are now the same
            )
        }
    }
}
