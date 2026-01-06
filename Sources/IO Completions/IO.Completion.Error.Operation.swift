//
//  IO.Completion.Error.Operation.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 31/12/2025.
//

extension IO.Completion.Error {
    /// Operation-specific errors.
    public enum Operation: Swift.Error, Sendable, Equatable {
        /// The operation was cancelled.
        case cancellation

        /// The operation timed out.
        case timeout

        /// Invalid operation submission.
        ///
        /// The operation parameters were invalid or inconsistent.
        case invalidSubmission

        /// The submission queue is full.
        ///
        /// The io_uring submission ring has no available slots.
        /// Caller should wait for completions or increase ring size.
        case queueFull
    }
}

// MARK: - CustomStringConvertible

extension IO.Completion.Error.Operation: CustomStringConvertible {
    public var description: String {
        switch self {
        case .cancellation: "cancelled"
        case .timeout: "timeout"
        case .invalidSubmission: "invalidSubmission"
        case .queueFull: "queueFull"
        }
    }
}
