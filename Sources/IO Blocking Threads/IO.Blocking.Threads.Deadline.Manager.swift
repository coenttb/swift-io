//
//  IO.Blocking.Threads.Deadline.Manager.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 24/12/2025.
//

extension IO.Blocking.Threads.Deadline {
    /// A dedicated thread that enforces acceptance deadlines.
    ///
    /// The deadline manager is a fixed infrastructure thread (not per-call).
    /// It ensures acceptance deadlines fire even when the queue is permanently saturated.
    ///
    /// - Single manager thread per Threads instance
    /// - Manager only touches acceptance waiters (not completion waiters)
    /// - All waiter access is under the shared lock
    final class Manager: Sendable {
        // ## Algorithm
        // 1. Wait on condvar with timeout = earliest deadline
        // 2. On wakeup (signal or timeout):
        //    - Scan acceptance waiters for expired deadlines
        //    - Resume expired waiters with `.timeout`
        //    - Compute next earliest deadline
        // 3. Repeat until shutdown
        //
        // ## Lazy Expiry Strategy
        // Expired waiters are marked as resumed but left in the ring buffer.
        // Their slots are reclaimed when `promoteAcceptanceWaiters()` dequeues them.
        // This ensures:
        // - Non-expired waiters behind expired ones are not starved
        // - Capacity is recovered as expired entries are drained
        private let state: IO.Blocking.Threads.Runtime.State

        init(state: IO.Blocking.Threads.Runtime.State) {
            self.state = state
        }

        /// Run the deadline manager loop until shutdown.
        func run() {
            while true {
                state.lock.lock()

                // Check shutdown
                if state.isShutdown {
                    state.lock.unlock()
                    return
                }

                // Find earliest deadline
                let earliestDeadline = findEarliestDeadline()

                if let deadline = earliestDeadline {
                    let remaining = deadline.remainingNanoseconds
                    if remaining > 0 {
                        // Wait until deadline (or signal) on deadline condvar
                        _ = state.lock.deadline.wait(timeout: UInt64(remaining))
                    }
                    // After wait, expire any past-due waiters
                    let expired = expireDeadlines()
                    state.lock.unlock()

                    // Fail expired waiters via their contexts (outside lock)
                    for waiter in expired {
                        _ = waiter.job.context.fail(.timeout)
                    }
                } else {
                    // No deadlines - wait indefinitely for signal on deadline condvar
                    state.lock.deadline.wait()
                    state.lock.unlock()
                }
            }
        }

        /// Find the earliest deadline among acceptance waiters.
        /// Must be called under lock.
        ///
        /// Delegates to Queue.findEarliestDeadline().
        private func findEarliestDeadline() -> IO.Blocking.Deadline? {
            state.acceptanceWaiters.findEarliestDeadline()
        }

        /// Mark expired waiters as resumed and collect them for resumption.
        /// Must be called under lock.
        ///
        /// ## Lazy Expiry
        /// Expired waiters remain in the ring buffer (marked resumed) until
        /// dequeue reclaims their slots. This avoids complex compaction while
        /// ensuring capacity recovery.
        ///
        /// Delegates to Queue.markExpiredResumed().
        private func expireDeadlines() -> [IO.Blocking.Threads.Acceptance.Waiter] {
            state.acceptanceWaiters.markExpiredResumed()
        }
    }
}
