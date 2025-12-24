//
//  IO.Blocking.Threads.Deadline.Manager.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 24/12/2025.
//

extension IO.Blocking.Threads.Deadline {
    /// A dedicated thread that enforces acceptance deadlines.
    ///
    /// ## Design
    /// The deadline manager is a fixed infrastructure thread (not per-call).
    /// It ensures acceptance deadlines fire even when the queue is permanently saturated.
    ///
    /// ## Algorithm
    /// 1. Wait on condvar with timeout = earliest deadline
    /// 2. On wakeup (signal or timeout):
    ///    - Scan acceptance waiters for expired deadlines
    ///    - Resume expired waiters with `.deadlineExceeded`
    ///    - Compute next earliest deadline
    /// 3. Repeat until shutdown
    ///
    /// ## Invariants
    /// - Single manager thread per Threads instance
    /// - Manager only touches acceptance waiters (not completion waiters)
    /// - All waiter access is under the shared lock
    final class Manager: Sendable {
        private let state: IO.Blocking.Threads.Thread.Worker.State

        init(state: IO.Blocking.Threads.Thread.Worker.State) {
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
                        // Wait until deadline (or signal)
                        _ = state.lock.wait(timeoutNanoseconds: UInt64(remaining))
                    }
                    // After wait, expire any past-due waiters
                    let expired = expireDeadlines()
                    state.lock.unlock()

                    // Resume expired waiters outside lock
                    for var waiter in expired {
                        waiter.resumeThrowing(.deadlineExceeded)
                    }
                } else {
                    // No deadlines - wait indefinitely for signal
                    state.lock.wait()
                    state.lock.unlock()
                }
            }
        }

        /// Find the earliest deadline among acceptance waiters.
        /// Must be called under lock.
        private func findEarliestDeadline() -> IO.Blocking.Deadline? {
            var earliest: IO.Blocking.Deadline?
            for waiter in state.acceptanceWaiters where !waiter.resumed {
                if let deadline = waiter.deadline {
                    if earliest == nil || deadline < earliest! {
                        earliest = deadline
                    }
                }
            }
            return earliest
        }

        /// Remove and return waiters whose deadlines have expired.
        /// Must be called under lock.
        private func expireDeadlines() -> [IO.Blocking.Threads.Acceptance.Waiter] {
            var expired: [IO.Blocking.Threads.Acceptance.Waiter] = []
            var remaining: [IO.Blocking.Threads.Acceptance.Waiter] = []

            for var waiter in state.acceptanceWaiters {
                if waiter.resumed {
                    // Already handled, skip
                    continue
                }
                if let deadline = waiter.deadline, deadline.hasExpired {
                    waiter.resumed = true
                    expired.append(waiter)
                } else {
                    remaining.append(waiter)
                }
            }

            state.acceptanceWaiters = remaining
            return expired
        }
    }
}
