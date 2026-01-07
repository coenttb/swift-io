//
//  IO.Blocking.Threads.Runtime.State.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 24/12/2025.
//

import Buffer
import Synchronization

extension IO.Blocking.Threads.Runtime {
    /// Shared mutable state for the lane, owned by Runtime.
    ///
    /// ## Safety Invariant (for @unchecked Sendable)
    /// All access to mutable fields is protected by `lock`.
    /// This is enforced through the Lock's `withLock` method.
    ///
    /// ## Design (Unified Single-Stage)
    /// Jobs carry their completion context, eliminating dictionary lookups:
    /// - Workers call `job.context.complete()` directly
    /// - Cancellation calls `job.context.cancel()` directly
    /// - Atomic state ensures exactly-once resumption
    ///
    /// ## Invariants (must hold under lock)
    /// 1. **Acceptance invariant**: A job is either waiting in acceptanceWaiters,
    ///    or accepted (in queue or being executed).
    /// 2. **Completion invariant**: Each context is resumed exactly once by:
    ///    - Worker calling `complete()`
    ///    - Cancellation calling `cancel()`
    ///    - Error path calling `fail()`
    /// 3. **Drain invariant**: After shutdown, no worker can touch shared state.
    final class State: @unchecked Sendable {
        let lock: Kernel.Thread.DualSync
        var queue: Buffer.Ring<IO.Blocking.Threads.Job.Instance>

        // Atomic shutdown flag - allows lock-free check in hot path
        private let _isShutdown: Atomic<Bool>

        // Atomic in-flight count - allows lock-free completion tracking
        private let _inFlightCount: Atomic<Int>

        // Ticket generation (atomic - no lock required)
        private let ticketCounter: Atomic<UInt64>

        // Acceptance waiters (queue full, backpressure .wait)
        // Bounded ring buffer - fails with .overloaded when full
        var acceptanceWaiters: IO.Blocking.Threads.Acceptance.Queue

        // MARK: - Metrics Counters (lock-free atomics)

        /// Lock-free atomic counters. No lock required for increment or read.
        let counters = IO.Blocking.Threads.Counters()

        // MARK: - Latency Aggregates (protected by lock)

        var enqueueToStartAggregate = IO.Blocking.Threads.Aggregate.Mutable()
        var executionAggregate = IO.Blocking.Threads.Aggregate.Mutable()
        var acceptanceWaitAggregate = IO.Blocking.Threads.Aggregate.Mutable()

        init(queueLimit: Int, acceptanceWaitersLimit: Int) {
            self.lock = Kernel.Thread.DualSync()
            self.queue = Buffer.Ring(capacity: queueLimit)
            self._isShutdown = Atomic(false)
            self._inFlightCount = Atomic(0)
            self.ticketCounter = Atomic(1)
            self.acceptanceWaiters = IO.Blocking.Threads.Acceptance.Queue(capacity: acceptanceWaitersLimit)
        }

        // MARK: - Atomic Accessors

        /// Computed property for lock-protected access (existing code compatibility).
        /// Must be called under lock for write operations.
        var isShutdown: Bool {
            get { _isShutdown.load(ordering: .acquiring) }
            set { _isShutdown.store(newValue, ordering: .releasing) }
        }

        /// Lock-free shutdown check for hot path.
        @inline(__always)
        var isShuttingDown: Bool {
            _isShutdown.load(ordering: .acquiring)
        }

        /// Computed property for lock-protected access (existing code compatibility).
        var inFlightCount: Int {
            get { _inFlightCount.load(ordering: .relaxed) }
            set { _inFlightCount.store(newValue, ordering: .relaxed) }
        }

        /// Lock-free increment for worker start.
        @inline(__always)
        func incrementInFlight() {
            _ = _inFlightCount.wrappingAdd(1, ordering: .relaxed)
        }

        /// Lock-free increment for batch start.
        @inline(__always)
        func addInFlight(_ count: Int) {
            _ = _inFlightCount.wrappingAdd(count, ordering: .relaxed)
        }

        /// Lock-free decrement for worker completion.
        @inline(__always)
        func decrementInFlight() {
            _ = _inFlightCount.wrappingSubtract(1, ordering: .relaxed)
        }

        /// Lock-free decrement for batch completion.
        @inline(__always)
        func subtractInFlight(_ count: Int) {
            _ = _inFlightCount.wrappingSubtract(count, ordering: .relaxed)
        }

        /// Generate a unique ticket. Lock-free via atomic increment.
        func makeTicket() -> IO.Blocking.Ticket {
            let raw = ticketCounter.wrappingAdd(1, ordering: .relaxed).oldValue
            return IO.Blocking.Ticket(rawValue: raw)
        }

        /// Wake sleeping workers when queue becomes non-empty.
        ///
        /// ## Invariant
        /// Must be called while holding `lock`, after queue transitioned empty→non-empty.
        ///
        /// ## Policy
        /// Broadcast to wake all sleeping workers, but only if waiters exist.
        /// Uses Kernel.Synchronization's waiter tracking to skip syscalls when no
        /// workers are sleeping.
        ///
        /// ## Correctness
        /// - Amortized cost is ≤k wakeups per busy period (not per job)
        /// - Thundering herd is bounded by pool size (small, 4-32)
        /// - Simplest invariant: edge-triggered broadcast
        ///
        /// ## Progress Guarantee
        /// If the queue transitions from empty to non-empty, workers must be woken.
        ///
        /// Uses **unconditional** `broadcast()` to prevent lost-wakeup race:
        /// - Worker threads may not yet be in `waitTracked()` when first job enqueues
        /// - `broadcastIfWaiters()` skips signal if `waiterCount == 0`
        /// - This creates a window: enqueue → broadcast skipped → workers sleep forever
        ///
        /// The broadcast syscall cost is acceptable because:
        /// - Only called on empty→non-empty transitions (edge-triggered)
        /// - Bounded by pool size (typically 4-32 workers)
        /// - Correctness > micro-optimization for wake syscalls
        @inline(__always)
        func wakeSleepersIfNeeded(didBecomeNonEmpty: Bool) {
            guard didBecomeNonEmpty else { return }
            lock.worker.broadcast()
        }

        /// Try to enqueue a job. Returns true if successful, false if queue is full or shutdown.
        /// Must be called under lock.
        func tryEnqueue(_ job: IO.Blocking.Threads.Job.Instance) -> Bool {
            guard !isShutdown else { return false }
            guard !queue.isFull else { return false }
            _ = queue.push(job)
            counters.incrementEnqueued()  // Lock-free atomic
            return true
        }

        /// Promote acceptance waiters when capacity becomes available.
        ///
        /// ## Unified Design
        /// Waiters now hold complete Job.Instance with bundled context.
        /// Promotion simply enqueues the job - the worker will complete it directly.
        ///
        /// ## Signal Discipline
        /// Signal only on empty→non-empty transition, and only if sleepers > 0.
        /// This prevents wasted kernel round-trips when workers are already active.
        ///
        /// ## Lazy Expiry
        /// Expired waiters are failed via `context.fail(.deadlineExceeded)`.
        ///
        /// ## Metrics
        /// Tracks `acceptancePromotedTotal`, `acceptanceTimeoutTotal`, and `acceptanceWaitAggregate`.
        ///
        /// Must be called under lock.
        func promoteAcceptanceWaiters() {
            var didTransitionFromEmpty = false
            let now = IO.Blocking.Deadline.now

            while !queue.isFull, !acceptanceWaiters.isEmpty {
                if isShutdown { break }

                // Dequeue skips already-resumed entries
                guard let waiter = acceptanceWaiters.dequeue() else { break }

                // Check deadline (lazy expiry)
                if let deadline = waiter.deadline, deadline.hasExpired {
                    // Fail via context - atomic, exactly-once
                    _ = waiter.job.context.fail(.timeout)
                    counters.incrementAcceptanceTimeout()  // Lock-free atomic
                    continue
                }

                // Track empty→non-empty transition
                let wasEmpty = queue.isEmpty

                // Enqueue the job (already has context bundled)
                if tryEnqueue(waiter.job) {
                    counters.incrementAcceptancePromoted()  // Lock-free atomic
                    // Record acceptance wait time if timestamp available
                    if let acceptanceTimestamp = waiter.job.acceptanceTimestamp {
                        let waitNs = now.nanosecondsSince(acceptanceTimestamp)
                        acceptanceWaitAggregate.record(waitNs)
                    }
                    if wasEmpty {
                        didTransitionFromEmpty = true
                    }
                    // Job enqueued - worker will complete via context
                } else {
                    // Shouldn't happen since we checked !queue.isFull
                    _ = waiter.job.context.fail(.failure(.queueFull))
                    break
                }
            }

            // Wake all sleeping workers if queue transitioned empty→non-empty
            wakeSleepersIfNeeded(didBecomeNonEmpty: didTransitionFromEmpty)
        }

        /// Mark an acceptance waiter as resumed by ticket. Returns the waiter if found.
        ///
        /// O(n) scan - acceptable with bounded capacity.
        /// The waiter stays in storage until dequeue reclaims its slot.
        /// Must be called under lock.
        func removeAcceptanceWaiter(ticket: IO.Blocking.Ticket) -> IO.Blocking.Threads.Acceptance.Waiter? {
            return acceptanceWaiters.markResumed(ticket: ticket)
        }
    }
}
