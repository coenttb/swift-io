//
//  IO.Blocking.Failure.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 24/12/2025.
//

extension IO.Blocking {
    /// Infrastructure failures from the lane.
    // Operation errors are returned in the boxed Result, not thrown.
    public enum Failure: Swift.Error, Sendable, Equatable {
        case shutdown
        case queueFull
        case deadlineExceeded
        case cancelled

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

        /// Internal invariant violation (should never occur in correct code).
        ///
        /// Indicates a bug in the lane implementation where an unexpected
        /// error type escaped through the continuation boundary.
        /// In debug builds, this triggers a precondition failure instead.
        case internalInvariantViolation
    }
}
