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
        var acceptanceWaiters: [IO.Blocking.Threads.Acceptance.Waiter]

        // Completion storage and waiters
        var completions: [IO.Blocking.Threads.Ticket: UnsafeMutableRawPointer]
        var completionWaiters: [IO.Blocking.Threads.Ticket: IO.Blocking.Threads.Completion.Waiter]

        init(queueLimit: Int) {
            self.lock = IO.Blocking.Threads.Lock()
            self.queue = IO.Blocking.Threads.Job.Queue(capacity: queueLimit)
            self.isShutdown = false
            self.inFlightCount = 0
            self.nextTicketRaw = 1
            self.acceptanceWaiters = []
            self.completions = [:]
            self.completionWaiters = [:]
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
        func promoteAcceptanceWaiters() -> [(IO.Blocking.Threads.Acceptance.Waiter, Result<IO.Blocking.Threads.Ticket, IO.Blocking.Failure>)] {
            var toResume: [(IO.Blocking.Threads.Acceptance.Waiter, Result<IO.Blocking.Threads.Ticket, IO.Blocking.Failure>)] = []

            while !queue.isFull, !acceptanceWaiters.isEmpty {
                if isShutdown { break }

                var waiter = acceptanceWaiters.removeFirst()
                if waiter.resumed { continue }

                // Check deadline
                if let deadline = waiter.deadline, deadline.hasExpired {
                    waiter.resumed = true
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
                    waiter.resumed = true
                    toResume.append((waiter, .success(ticket)))
                    lock.signal()
                } else {
                    // Couldn't enqueue - put back and stop
                    acceptanceWaiters.insert(waiter, at: 0)
                    break
                }
            }

            return toResume
        }

        /// Store or deliver a job completion. Must be called under lock.
        func complete(ticket: IO.Blocking.Threads.Ticket, box: sending UnsafeMutableRawPointer) {
            lock.lock()
            defer { lock.unlock() }

            if var waiter = completionWaiters.removeValue(forKey: ticket) {
                #if DEBUG
                precondition(!waiter.resumed, "Completion waiter already resumed")
                #endif

                if waiter.abandoned {
                    // Waiter cancelled - free the box
                    // Note: We don't know the exact Result type here, so we just deallocate.
                    // The operation closure already ran, we're just freeing memory.
                    box.deallocate()
                    waiter.resumed = true
                    return
                }

                waiter.resumed = true
                waiter.continuation.resume(returning: box)
                return
            }

            // No waiter yet - store for later pickup
            completions[ticket] = box
        }

        /// Remove an acceptance waiter by ticket. Returns true if found and removed.
        /// Must be called under lock.
        func removeAcceptanceWaiter(ticket: IO.Blocking.Threads.Ticket) -> Bool {
            if let index = acceptanceWaiters.firstIndex(where: { $0.ticket == ticket && !$0.resumed }) {
                acceptanceWaiters.remove(at: index)
                return true
            }
            return false
        }
    }
}
