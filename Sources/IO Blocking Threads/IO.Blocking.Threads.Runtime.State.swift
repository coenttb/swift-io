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
        let lock: Kernel.Thread.Executor.DualSync
        var queue: Buffer.Ring<IO.Blocking.Threads.Job.Instance>
        var isShutdown: Bool
        var inFlightCount: Int

        // Ticket generation (atomic - no lock required)
        private let ticketCounter: Atomic<UInt64>

        // Acceptance waiters (queue full, backpressure .wait)
        // Bounded ring buffer - fails with .overloaded when full
        var acceptanceWaiters: IO.Blocking.Threads.Acceptance.Queue

        init(queueLimit: Int, acceptanceWaitersLimit: Int) {
            self.lock = Kernel.Thread.Executor.DualSync()
            self.queue = Buffer.Ring(capacity: queueLimit)
            self.isShutdown = false
            self.inFlightCount = 0
            self.ticketCounter = Atomic(1)
            self.acceptanceWaiters = IO.Blocking.Threads.Acceptance.Queue(capacity: acceptanceWaitersLimit)
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
        /// If the queue transitions from empty to non-empty while waiters exist,
        /// the system cannot remain in a stable state where `Q ≠ ∅` and workers
        /// are sleeping without further enqueues.
        @inline(__always)
        func wakeSleepersIfNeeded(didBecomeNonEmpty: Bool) {
            guard didBecomeNonEmpty else { return }
            lock.worker.broadcastIfWaiters()
        }

        /// Try to enqueue a job. Returns true if successful, false if queue is full or shutdown.
        /// Must be called under lock.
        func tryEnqueue(_ job: IO.Blocking.Threads.Job.Instance) -> Bool {
            guard !isShutdown else { return false }
            guard !queue.isFull else { return false }
            queue.enqueue(job)
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
        /// Must be called under lock.
        func promoteAcceptanceWaiters() {
            var didTransitionFromEmpty = false

            while !queue.isFull, !acceptanceWaiters.isEmpty {
                if isShutdown { break }

                // Dequeue skips already-resumed entries
                guard let waiter = acceptanceWaiters.dequeue() else { break }

                // Check deadline (lazy expiry)
                if let deadline = waiter.deadline, deadline.hasExpired {
                    // Fail via context - atomic, exactly-once
                    _ = waiter.job.context.fail(.timeout)
                    continue
                }

                // Track empty→non-empty transition
                let wasEmpty = queue.isEmpty

                // Enqueue the job (already has context bundled)
                if tryEnqueue(waiter.job) {
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
