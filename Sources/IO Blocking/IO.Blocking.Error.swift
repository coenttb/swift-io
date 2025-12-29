//
//  IO.Blocking.Error.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 28/12/2025.
//

extension IO.Blocking {
    /// Public error subset for lane infrastructure failures.
    ///
    /// This type excludes lifecycle concerns (shutdown/cancellation) which
    /// are surfaced through `IO.Lifecycle.Error` at the Pool boundary.
    ///
    /// ## Design
    /// - No `Equatable` conformance to preserve payload flexibility for future.
    /// - Maps from internal `Failure` type, filtering out lifecycle cases.
    /// - This ensures wrong-category errors are statically unrepresentable.
    ///
    /// ## Usage
    /// This type is used in `IO.Error<E>.lane(IO.Blocking.Error)` to represent
    /// lane infrastructure failures that are not lifecycle-related.
    public enum Error: Swift.Error, Sendable {
        /// The lane's job queue is full.
        /// Callers may retry with backoff.
        case queueFull

        /// The deadline expired before the operation was accepted.
        case deadlineExceeded

        /// The lane's waiter capacity is exhausted (bounded memory protection).
        /// Callers may retry with backoff.
        case overloaded

        /// Internal invariant violation.
        case internalInvariantViolation
        // (should never occur in correct code).
    }
}

// MARK: - Mapping from Internal Failure

extension IO.Blocking.Error {
    /// Failable initializer from internal `Failure` type.
    ///
    /// Returns `nil` for lifecycle cases (shutdown/cancellationRequested)
    /// which are handled at the Pool boundary and surfaced as
    /// `IO.Lifecycle.Error` instead.
    internal init?(_ failure: IO.Blocking.Failure) {
        switch failure {
        case .shutdown, .cancellationRequested:
            // Lifecycle cases - handled at Pool boundary
            return nil
        case .queueFull:
            self = .queueFull
        case .deadlineExceeded:
            self = .deadlineExceeded
        case .overloaded:
            self = .overloaded
        case .internalInvariantViolation:
            self = .internalInvariantViolation
        }
    }
}

// MARK: - CustomStringConvertible

extension IO.Blocking.Error: CustomStringConvertible {
    public var description: String {
        switch self {
        case .queueFull:
            return "Queue full"
        case .deadlineExceeded:
            return "Deadline exceeded"
        case .overloaded:
            return "Overloaded"
        case .internalInvariantViolation:
            return "Internal invariant violation"
        }
    }
}
