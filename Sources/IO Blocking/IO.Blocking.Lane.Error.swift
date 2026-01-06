//
//  IO.Blocking.Lane.Error.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 28/12/2025.
//

extension IO.Blocking.Lane {
    /// Operational errors from Lane infrastructure.
    ///
    /// This type excludes lifecycle concerns (shutdown/cancellation/timeout) which
    /// are surfaced through `IO.Lifecycle.Error` at the Pool boundary.
    ///
    /// ## Design
    /// - Lifecycle cases (shutdown, cancellation, timeout) are in `IO.Lifecycle.Error`
    /// - Operational cases (queue full, overloaded) are in `Lane.Error`
    /// - This ensures wrong-category errors are statically unrepresentable.
    public enum Error: Swift.Error, Sendable, Equatable {
        /// The lane's job queue is full.
        /// Callers may retry with backoff.
        case queueFull

        /// The lane's waiter capacity is exhausted (bounded memory protection).
        /// Callers may retry with backoff.
        case overloaded

        /// Internal invariant violation (should never occur in correct code).
        case internalInvariantViolation
    }
}

// MARK: - CustomStringConvertible

extension IO.Blocking.Lane.Error: CustomStringConvertible {
    public var description: String {
        switch self {
        case .queueFull:
            return "Queue full"
        case .overloaded:
            return "Overloaded"
        case .internalInvariantViolation:
            return "Internal invariant violation"
        }
    }
}
