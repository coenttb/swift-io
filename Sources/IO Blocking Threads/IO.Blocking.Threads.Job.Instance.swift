//
//  IO.Blocking.Threads.Job.Instance.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 24/12/2025.
//

extension IO.Blocking.Threads.Job {
    /// A job that executes an operation and completes via its bundled context.
    ///
    /// ## Design
    /// The context is bundled with the job, eliminating dictionary lookups.
    /// The worker calls `context.complete()` directly after execution.
    ///
    /// ## Safety Invariant (for @unchecked Sendable)
    /// - Jobs are created and consumed under the Worker.State lock
    /// - The operation closure is marked @Sendable and captures only Sendable state
    /// - The context is Sendable (uses atomic state for thread-safe resumption)
    ///
    /// ## Exactly-Once Completion
    /// - If `context.complete()` returns false, the context was already cancelled
    /// - In that case, the box is destroyed to prevent leaks
    struct Instance: @unchecked Sendable {
        /// The ticket identifying this job (for debugging/logging).
        let ticket: IO.Blocking.Threads.Ticket

        /// The context for exactly-once completion resumption.
        let context: IO.Blocking.Threads.Completion.Context

        /// The operation that produces the boxed result.
        private let operation: @Sendable () -> UnsafeMutableRawPointer

        /// Creates a job with a bundled completion context.
        ///
        /// - Parameters:
        ///   - ticket: Unique identifier for this job
        ///   - context: The completion context (owns the continuation)
        ///   - operation: The blocking operation that produces a boxed result
        init(
            ticket: IO.Blocking.Threads.Ticket,
            context: IO.Blocking.Threads.Completion.Context,
            operation: @Sendable @escaping () -> UnsafeMutableRawPointer
        ) {
            self.ticket = ticket
            self.context = context
            self.operation = operation
        }

        /// Execute the job and complete via the context.
        ///
        /// ## Completion Flow
        /// 1. Execute the operation to produce a boxed result
        /// 2. Try to complete the context with the box
        /// 3. If cancelled, destroy the box to prevent leaks
        func run() {
            let box = operation()
            if !context.complete(with: IO.Blocking.Box.Pointer(box)) {
                // Context was already cancelled - destroy the box
                IO.Blocking.Box.destroy(box)
            }
        }
    }
}
