//
//  IO.Blocking.Threads.Acceptance.Waiter.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 24/12/2025.
//

extension IO.Blocking.Threads.Acceptance {
    /// A pending acceptance waiting for queue capacity.
    ///
    /// ## Design (Unified Single-Stage)
    /// The waiter holds a complete Job.Instance (with bundled context).
    /// When promoted (capacity becomes available):
    /// 1. Enqueue the job
    /// 2. Worker will complete the job's context directly
    ///
    /// When cancelled or expired:
    /// - Call `job.context.tryCancel()` or `job.context.tryFail()`
    /// - The atomic context ensures exactly-once resumption
    struct Waiter {
        /// The job to enqueue when capacity is available.
        ///
        /// Contains: ticket, context (owns continuation), operation
        let job: IO.Blocking.Threads.Job.Instance

        /// Optional deadline for acceptance.
        let deadline: IO.Blocking.Deadline?

        /// Whether this waiter has been processed.
        ///
        /// Used by the Queue to skip already-resumed entries during iteration.
        var resumed: Bool

        init(
            job: IO.Blocking.Threads.Job.Instance,
            deadline: IO.Blocking.Deadline?,
            resumed: Bool = false
        ) {
            self.job = job
            self.deadline = deadline
            self.resumed = resumed
        }

        /// The ticket for this waiter (delegates to job).
        var ticket: IO.Blocking.Threads.Ticket {
            job.ticket
        }
    }
}
