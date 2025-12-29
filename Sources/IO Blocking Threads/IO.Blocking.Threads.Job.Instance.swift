//
//  IO.Blocking.Threads.Job.Instance.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 24/12/2025.
//

extension IO.Blocking.Threads.Job {
    /// A job that executes a non-throwing operation and calls onComplete with the result pointer.
    /// Allocation happens inside job execution, not before enqueue.
    struct Instance: @unchecked Sendable {
        /// The ticket identifying this job for completion correlation.
        let ticket: IO.Blocking.Threads.Ticket

        private let work: @Sendable () -> Void

        /// Creates a job that executes a non-throwing operation and calls onComplete.

    //
    // ## Safety Invariant (for @unchecked Sendable)
    // Jobs are created and consumed under the Worker.State lock.
    // The work closure is marked @Sendable and captures only Sendable state.
    //
    // ## Boxing Ownership
    // The operation returns a boxed Result (UnsafeMutableRawPointer).
        /// The operation returns a boxed Result (already containing any error).
        ///
        /// The `sending` annotation on `onComplete` parameter indicates ownership
        /// of the pointer is transferred to the callback, satisfying concurrency safety.
        init(
            ticket: IO.Blocking.Threads.Ticket,
            operation: @Sendable @escaping () -> UnsafeMutableRawPointer,
            onComplete: @Sendable @escaping (sending IO.Blocking.Threads.Ticket, sending UnsafeMutableRawPointer) -> Void
        ) {
            self.ticket = ticket
            self.work = { [ticket] in
                let ptr = operation()
                onComplete(ticket, ptr)
            }
        }

        /// An empty placeholder job.
        static let empty = Instance(ticket: .init(rawValue: 0)) {}

        private init(ticket: IO.Blocking.Threads.Ticket, _ work: @Sendable @escaping () -> Void) {
            self.ticket = ticket
            self.work = work
        }

        /// Execute the job.
        func run() {
            work()
        }
    }
}
