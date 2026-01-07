//
//  IO.Blocking.Threads.Acceptance.Waiter.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 24/12/2025.
//

extension IO.Blocking.Threads.Acceptance {
    /// A pending acceptance waiting for queue capacity.
    ///
    /// ## Design (WaiterCell for O(1) Cancellation)
    /// Uses a class (reference semantics) so that the same cell instance is
    /// shared between the ring buffer and the index table. When cancelled,
    /// we mark the cell as resumed via the index table. The ring buffer then
    /// skips it during dequeue (lazy skip pattern).
    ///
    /// ## Unified Single-Stage
    /// The cell holds a complete Job.Instance (with bundled context).
    /// When promoted (capacity becomes available):
    /// 1. Enqueue the job
    /// 2. Worker will complete the job's context directly
    ///
    /// When cancelled or expired:
    /// - Call `job.context.cancel()` or `job.context.fail()`
    /// - The atomic context ensures exactly-once resumption
    ///
    /// ## Thread Safety
    /// All access is protected by `Runtime.State.lock`.
    final class WaiterCell {
        /// The ticket for O(1) lookup in the index table.
        let ticket: IO.Blocking.Ticket

        /// The job to enqueue when capacity is available.
        ///
        /// Contains: ticket, context (owns continuation), operation
        let job: IO.Blocking.Threads.Job.Instance

        /// Optional deadline for acceptance.
        let deadline: IO.Blocking.Deadline?

        /// Whether this waiter has been processed.
        ///
        /// Used by the Queue to skip already-resumed entries during dequeue.
        /// Protected by `Runtime.State.lock`.
        var resumed: Bool

        init(
            ticket: IO.Blocking.Ticket,
            job: IO.Blocking.Threads.Job.Instance,
            deadline: IO.Blocking.Deadline?
        ) {
            self.ticket = ticket
            self.job = job
            self.deadline = deadline
            self.resumed = false
        }
    }

    /// Immutable snapshot of a waiter for external use.
    ///
    /// Returned by dequeue operations to preserve the old API contract.
    struct Waiter {
        /// The job to enqueue when capacity is available.
        let job: IO.Blocking.Threads.Job.Instance

        /// Optional deadline for acceptance.
        let deadline: IO.Blocking.Deadline?

        /// Whether this waiter has been processed.
        var resumed: Bool

        /// The ticket for this waiter (delegates to job).
        var ticket: IO.Blocking.Ticket {
            job.ticket
        }

        init(
            job: IO.Blocking.Threads.Job.Instance,
            deadline: IO.Blocking.Deadline?,
            resumed: Bool = false
        ) {
            self.job = job
            self.deadline = deadline
            self.resumed = resumed
        }

        /// Create from a cell.
        init(_ cell: WaiterCell) {
            self.job = cell.job
            self.deadline = cell.deadline
            self.resumed = cell.resumed
        }
    }
}
