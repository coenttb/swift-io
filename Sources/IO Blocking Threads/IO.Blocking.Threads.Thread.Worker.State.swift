//
//  IO.Blocking.Threads.Thread.Worker.State.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 24/12/2025.
//

import Synchronization

extension IO.Blocking.Threads.Thread.Worker {
    /// Shared mutable state for all workers in the lane.
    ///
    /// ## Safety Invariant (for @unchecked Sendable)
    /// All access to mutable fields is protected by `lock`.
    /// This is enforced through the Lock's `withLock` method.
    ///
    /// ## Design (Unified Single-Stage)
    /// Jobs carry their completion context, eliminating dictionary lookups:
    /// - Workers call `job.context.tryComplete()` directly
    /// - Cancellation calls `job.context.tryCancel()` directly
    /// - Atomic state ensures exactly-once resumption
    ///
    /// ## Invariants (must hold under lock)
    /// 1. **Acceptance invariant**: A job is either waiting in acceptanceWaiters,
    ///    or accepted (in queue or being executed).
    /// 2. **Completion invariant**: Each context is resumed exactly once by:
    ///    - Worker calling `tryComplete()`
    ///    - Cancellation calling `tryCancel()`
    ///    - Error path calling `tryFail()`
    /// 3. **Drain invariant**: After shutdown, no worker can touch shared state.
    final class State: @unchecked Sendable {
        let lock: IO.Blocking.Threads.Lock
        var queue: IO.Blocking.Threads.Job.Queue
        var isShutdown: Bool
        var inFlightCount: Int

        // Ticket generation (atomic - no lock required)
        private let ticketCounter: Atomic<UInt64>

        // Acceptance waiters (queue full, backpressure .wait)
        // Bounded ring buffer - fails with .overloaded when full
        var acceptanceWaiters: IO.Blocking.Threads.Acceptance.Queue

        init(queueLimit: Int, acceptanceWaitersLimit: Int) {
            self.lock = IO.Blocking.Threads.Lock()
            self.queue = IO.Blocking.Threads.Job.Queue(capacity: queueLimit)
            self.isShutdown = false
            self.inFlightCount = 0
            self.ticketCounter = Atomic(1)
            self.acceptanceWaiters = IO.Blocking.Threads.Acceptance.Queue(capacity: acceptanceWaitersLimit)
        }

        /// Generate a unique ticket. Lock-free via atomic increment.
        func makeTicket() -> IO.Blocking.Threads.Ticket {
            let raw = ticketCounter.wrappingAdd(1, ordering: .relaxed).oldValue
            return IO.Blocking.Threads.Ticket(rawValue: raw)
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
        /// ## Lazy Expiry
        /// Expired waiters are failed via `context.tryFail(.deadlineExceeded)`.
        ///
        /// Must be called under lock.
        func promoteAcceptanceWaiters() {
            while !queue.isFull, !acceptanceWaiters.isEmpty {
                if isShutdown { break }

                // Dequeue skips already-resumed entries
                guard let waiter = acceptanceWaiters.dequeue() else { break }

                // Check deadline (lazy expiry)
                if let deadline = waiter.deadline, deadline.hasExpired {
                    // Fail via context - atomic, exactly-once
                    _ = waiter.job.context.tryFail(.deadlineExceeded)
                    continue
                }

                // Enqueue the job (already has context bundled)
                if tryEnqueue(waiter.job) {
                    lock.signalWorker()
                    // Job enqueued - worker will complete via context
                } else {
                    // Shouldn't happen since we checked !queue.isFull
                    _ = waiter.job.context.tryFail(.queueFull)
                    break
                }
            }
        }

        /// Mark an acceptance waiter as resumed by ticket. Returns the waiter if found.
        ///
        /// O(n) scan - acceptable with bounded capacity.
        /// The waiter stays in storage until dequeue reclaims its slot.
        /// Must be called under lock.
        func removeAcceptanceWaiter(ticket: IO.Blocking.Threads.Ticket) -> IO.Blocking.Threads.Acceptance.Waiter? {
            return acceptanceWaiters.markResumed(ticket: ticket)
        }
    }
}
