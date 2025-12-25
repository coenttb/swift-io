//
//  IO.Blocking.Threads.Thread.Worker.State.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 24/12/2025.
//

extension IO.Blocking.Threads.Thread.Worker {
    /// Shared mutable state for all workers in the lane.
    ///
    /// ## Safety Invariant (for @unchecked Sendable)
    /// All access to mutable fields is protected by `lock`.
    /// This is enforced through the Lock's `withLock` method.
    ///
    /// ## Invariants (must hold under lock)
    /// 1. **Acceptance invariant**: A ticket is either not yet accepted (in acceptanceWaiters),
    ///    or accepted exactly once (in queue or already executed).
    /// 2. **Completion invariant**: For an accepted ticket, exactly one of:
    ///    - completion stored in `completions`
    ///    - completion waiter present in `completionWaiters`
    ///    - completion freed immediately due to abandonment
    /// 3. **Drain invariant**: After shutdown returns, no worker thread can still touch
    ///    shared state; acceptanceWaiters, completionWaiters, completions, and queue are empty.
    final class State: @unchecked Sendable {
        let lock: IO.Blocking.Threads.Lock
        var queue: IO.Blocking.Threads.Job.Queue
        var isShutdown: Bool
        var inFlightCount: Int

        // Ticket generation
        var nextTicketRaw: UInt64

        // Acceptance waiters (queue full, backpressure .suspend)
        // Bounded ring buffer - fails with .overloaded when full
        var acceptanceWaiters: IO.Blocking.Threads.Acceptance.Queue

        // Completion storage and waiters
        var completions: [IO.Blocking.Threads.Ticket: UnsafeMutableRawPointer]
        var completionWaiters: [IO.Blocking.Threads.Ticket: IO.Blocking.Threads.Completion.Waiter]

        // Tickets abandoned before waiter registration (early cancellation)
        var abandonedTickets: Set<IO.Blocking.Threads.Ticket>

        #if DEBUG
        // Tracking for exactly-once Box destruction invariant
        var destroyedTickets: Set<IO.Blocking.Threads.Ticket> = []
        #endif

        init(queueLimit: Int, acceptanceWaitersLimit: Int) {
            self.lock = IO.Blocking.Threads.Lock()
            self.queue = IO.Blocking.Threads.Job.Queue(capacity: queueLimit)
            self.isShutdown = false
            self.inFlightCount = 0
            self.nextTicketRaw = 1
            self.acceptanceWaiters = IO.Blocking.Threads.Acceptance.Queue(capacity: acceptanceWaitersLimit)
            self.completions = [:]
            self.completionWaiters = [:]
            self.abandonedTickets = []
        }

        /// Generate a unique ticket. Must be called under lock.
        func makeTicket() -> IO.Blocking.Threads.Ticket {
            let ticket = IO.Blocking.Threads.Ticket(rawValue: nextTicketRaw)
            nextTicketRaw &+= 1
            return ticket
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
        /// Must be called under lock. Resumes continuations outside lock if needed.
        /// Returns waiters that should be resumed.
        ///
        /// ## Lazy Expiry
        /// Expired waiters are resumed with `.deadlineExceeded` and their slots reclaimed.
        /// This ensures non-expired waiters behind expired ones are not starved.
        func promoteAcceptanceWaiters() -> [(IO.Blocking.Threads.Acceptance.Waiter, Result<IO.Blocking.Threads.Ticket, IO.Blocking.Failure>)] {
            var toResume: [(IO.Blocking.Threads.Acceptance.Waiter, Result<IO.Blocking.Threads.Ticket, IO.Blocking.Failure>)] = []

            while !queue.isFull, !acceptanceWaiters.isEmpty {
                if isShutdown { break }

                // Dequeue skips already-resumed entries
                guard let waiter = acceptanceWaiters.dequeue() else { break }

                // Check deadline (lazy expiry)
                if let deadline = waiter.deadline, deadline.hasExpired {
                    toResume.append((waiter, .failure(.deadlineExceeded)))
                    continue
                }

                // Create and enqueue the job
                let ticket = waiter.ticket
                let job = IO.Blocking.Threads.Job.Instance(
                    ticket: ticket,
                    operation: waiter.operation
                ) { [weak self] ticket, box in
                    self?.complete(ticket: ticket, box: box)
                }

                if tryEnqueue(job) {
                    toResume.append((waiter, .success(ticket)))
                    lock.signalWorker()
                } else {
                    // Couldn't enqueue - can't put back in ring buffer easily
                    // This shouldn't happen since we checked !queue.isFull
                    // If it does, resume with failure
                    toResume.append((waiter, .failure(.queueFull)))
                    break
                }
            }

            return toResume
        }

        /// Store or deliver a job completion.
        ///
        /// ## Single-Resumer Authority
        /// Only one path can resume a waiter:
        /// - If ticket is abandoned: cancellation already resumed (or will resume), destroy box
        /// - If waiter exists: remove and resume with box (cancellation can't see it now)
        /// - Otherwise: store for later waiter pickup
        ///
        /// Takes the lock internally - callers must not hold the lock.
        func complete(ticket: IO.Blocking.Threads.Ticket, box: UnsafeMutableRawPointer) {
            lock.lock()
            defer { lock.unlock() }

            // If abandoned, cancellation already handled resumption - just destroy box
            if abandonedTickets.remove(ticket) != nil {
                #if DEBUG
                precondition(!destroyedTickets.contains(ticket), "Box already destroyed for ticket \(ticket)")
                destroyedTickets.insert(ticket)
                #endif
                IO.Blocking.Box.destroy(box)
                return
            }

            // If waiter exists, we own resumption - remove and resume
            if var waiter = completionWaiters.removeValue(forKey: ticket) {
                waiter.resumeReturning(IO.Blocking.Box.Pointer(box))
                return
            }

            // No waiter yet - store for later pickup
            completions[ticket] = box
        }

        /// Mark an acceptance waiter as resumed by ticket. Returns the waiter if found.
        ///
        /// O(n) scan - acceptable with bounded capacity.
        /// The waiter stays in storage until dequeue reclaims its slot.
        /// Must be called under lock.
        func removeAcceptanceWaiter(ticket: IO.Blocking.Threads.Ticket) -> IO.Blocking.Threads.Acceptance.Waiter? {
            return acceptanceWaiters.markResumed(ticket: ticket)
        }

        /// Destroy a box and track the destruction (debug builds only).
        ///
        /// Used by external callers (Threads.swift) that already hold the lock
        /// and have removed the completion from the dictionary.
        /// Must be called under lock.
        func destroyBox(ticket: IO.Blocking.Threads.Ticket, box: UnsafeMutableRawPointer) {
            #if DEBUG
            precondition(!destroyedTickets.contains(ticket), "Box already destroyed for ticket \(ticket)")
            destroyedTickets.insert(ticket)
            #endif
            IO.Blocking.Box.destroy(box)
        }
    }
}
