//
//  IO.Blocking.Lane.Inline.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 24/12/2025.
//

extension IO.Blocking.Lane {
    /// An inline lane that executes on the caller's context.
    ///
    /// ## Warning
    /// This lane is NOT suitable for actual blocking I/O operations.
    /// Blocking on this lane will block the cooperative thread pool.
    ///
    /// ## Use Cases
    /// - Unit testing with mock operations
    /// - Swift Embedded targets without pthread
    /// - Debugging orchestration logic
    ///
    /// ## Capabilities
    /// - `executesOnDedicatedThreads`: false
    /// - `guaranteesRunOnceEnqueued`: true (immediate execution)
    ///
    /// ## Deadline Behavior
    /// Deadlines are checked once before execution. No queue exists,
    /// so there is no "acceptance wait" that could exceed a deadline.
    ///
    /// ## Cancellation
    /// Respects cancellation before execution. Once started,
    /// the operation runs to completion (same invariant as Threads lane).
    public static var inline: Self {
        Self(
            capabilities: IO.Blocking.Capabilities(
                executesOnDedicatedThreads: false,
                guaranteesRunOnceEnqueued: true
            ),
            run: {
                (
                    deadline: IO.Blocking.Deadline?,
                    operation: @Sendable @escaping () -> UnsafeMutableRawPointer
                ) async throws(IO.Blocking.Failure) -> UnsafeMutableRawPointer in
                // Check cancellation before execution
                if Task.isCancelled {
                    throw .cancelled
                }
                // Check deadline (one-time check, no queue)
                if let deadline, deadline.hasExpired {
                    throw .deadlineExceeded
                }
                // Execute immediately on caller's context
                return operation()
            },
            shutdown: { /* no-op: nothing to shut down */  }
        )
    }
}
