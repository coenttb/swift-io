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
    ///
    /// ## Typed Throws via Result
    /// Uses `CheckedContinuation<Result<Ticket, IO.Lifecycle.Error<Failure>>, Never>`
    /// instead of `CheckedContinuation<Ticket, any Error>` to preserve typed throws.
    /// The continuation never throws; errors flow through the Result type.
    /// This avoids `any Error` leaking into storage types.
    ///
    /// Lifecycle conditions (shutdown) are expressed via `IO.Lifecycle.Error`,
    /// keeping the leaf `Failure` type free of lifecycle concerns.
    struct Waiter {
        /// The ticket assigned to this job.
        let ticket: IO.Blocking.Threads.Ticket

        /// Optional deadline for acceptance.
        let deadline: IO.Blocking.Deadline?

        /// The operation to execute once accepted.
        let operation: @Sendable () -> UnsafeMutableRawPointer

        /// The continuation to resume when accepted or failed.
        let continuation:
            CheckedContinuation<
                Result<IO.Blocking.Threads.Ticket, IO.Lifecycle.Error<IO.Blocking.Failure>>,
                Never
            >

        /// Whether this waiter has been resumed. Used for DEBUG assertions.
        var resumed: Bool

        init(
            ticket: IO.Blocking.Threads.Ticket,
            deadline: IO.Blocking.Deadline?,
            operation: @escaping @Sendable () -> UnsafeMutableRawPointer,
            continuation: CheckedContinuation<
                Result<IO.Blocking.Threads.Ticket, IO.Lifecycle.Error<IO.Blocking.Failure>>,
                Never
            >,
            resumed: Bool = false
        ) {
            self.ticket = ticket
            self.deadline = deadline
            self.operation = operation
            self.continuation = continuation
            self.resumed = resumed
        }

        /// Resume this waiter exactly once with the given outcome.
        ///
        /// - Precondition: Must not have been resumed before.
        mutating func resume(
            with outcome: Result<IO.Blocking.Threads.Ticket, IO.Lifecycle.Error<IO.Blocking.Failure>>
        ) {
            #if DEBUG
                precondition(!resumed, "Acceptance waiter resumed more than once")
            #endif
            resumed = true
            continuation.resume(returning: outcome)
        }

        // MARK: - Convenience Resume

        /// Resume with an error (lifecycle or leaf failure).
        ///
        /// Wraps the error in `Result.failure(...)` internally, hiding
        /// the transport layer from call sites.
        ///
        /// Usage:
        /// - `waiter.resume(with: .failure(.deadlineExceeded))` for leaf failures
        /// - `waiter.resume(with: .lifecycle(.shutdownInProgress))` for lifecycle
        mutating func resume(with error: IO.Lifecycle.Error<IO.Blocking.Failure>) {
            resume(with: .failure(error))
        }
    }
}
