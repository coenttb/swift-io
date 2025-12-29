//
//  IO.Blocking.Threads.Acceptance.Waiter.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 24/12/2025.
//

extension IO.Blocking.Threads.Acceptance {
    /// A pending acceptance waiting for queue capacity.
    ///
    /// Created when the queue is full and backpressure policy is `.suspend`.
    /// The waiter carries the operation so it can be enqueued when capacity
    /// becomes available.
    struct Waiter {
        /// The ticket assigned to this job.
        let ticket: IO.Blocking.Threads.Ticket

        /// Optional deadline for acceptance.
        let deadline: IO.Blocking.Deadline?

        /// The operation to execute once accepted.
        let operation: @Sendable () -> UnsafeMutableRawPointer

        /// The continuation to resume when accepted or failed.
        let continuation: CheckedContinuation<IO.Blocking.Threads.Ticket, any Error>

        /// Whether this waiter has been resumed. Used for DEBUG assertions.
        var resumed: Bool

        init(
            ticket: IO.Blocking.Threads.Ticket,
            deadline: IO.Blocking.Deadline?,
            operation: @escaping @Sendable () -> UnsafeMutableRawPointer,
            continuation: CheckedContinuation<IO.Blocking.Threads.Ticket, any Error>,
            resumed: Bool = false
        ) {
            self.ticket = ticket
            self.deadline = deadline
            self.operation = operation
            self.continuation = continuation
            self.resumed = resumed
        }

        /// Resume this waiter exactly once with success.
        ///
        /// - Precondition: Must not have been resumed before.
        mutating func resumeReturning(_ ticket: IO.Blocking.Threads.Ticket) {
            #if DEBUG
                precondition(!resumed, "Acceptance waiter resumed more than once")
            #endif
            resumed = true
            continuation.resume(returning: ticket)
        }

        /// Resume this waiter exactly once with failure.
        ///
        /// - Precondition: Must not have been resumed before.
        mutating func resumeThrowing(_ error: IO.Blocking.Failure) {
            #if DEBUG
                precondition(!resumed, "Acceptance waiter resumed more than once")
            #endif
            resumed = true
            continuation.resume(throwing: error)
        }
    }
}
