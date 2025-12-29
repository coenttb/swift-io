//
//  IO.Blocking.Failure.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 24/12/2025.
//

extension IO.Blocking {
    /// Infrastructure failures from the Lane itself.
    ///
    /// This type is the internal lane contract. Lifecycle cases (`.shutdown`,
    /// `.cancellationRequested`) are mapped to `IO.Lifecycle.Error` at the Pool boundary.
    ///
    /// ## Stability
    /// This type is part of the Lane implementation contract. Do not match
    /// lifecycle cases directly in user code - use Pool which maps them to
    /// `IO.Lifecycle.Error` for correct error category handling.
    ///
    /// Operation errors are returned in the boxed Result, not thrown.
    public enum Failure: Swift.Error, Sendable, Equatable {
        /// The lane is shutting down.
        /// Mapped to `IO.Lifecycle.Error.shutdownInProgress` at Pool boundary.
        case shutdown

        /// Cancellation was requested.
        /// Mapped to `IO.Lifecycle.Error.cancelled` at Pool boundary.
        case cancellationRequested

        case queueFull
        case deadlineExceeded

        /// Lane infrastructure waiter capacity exhausted (bounded memory protection).
        ///
        /// This is a LANE-LEVEL failure, not a resource/handle overload.
        /// It means the lane's internal acceptance queue is full, preventing
        /// new operations from being enqueued.
        ///
        /// - Note: Distinct from `queueFull` which refers to the job queue.
        ///   This refers to the waiter queue for tasks awaiting acceptance.
        /// - Callers may retry with backoff.
        case overloaded

        /// Internal invariant violation.
        case internalInvariantViolation

        //
        // Indicates a bug in the lane implementation where an unexpected
        // error type escaped through the continuation boundary.
        // In debug builds, this triggers a precondition failure instead.
    }
}
