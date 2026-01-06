//
//  IO.Completion.Outcome.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 31/12/2025.
//

public import IO_Primitives
public import Kernel

extension IO.Completion {
    /// The outcome of a completed operation.
    ///
    /// Represents the three possible outcomes:
    /// - `success`: Operation completed successfully
    /// - `failure`: Operation failed with a kernel error
    /// - `cancelled`: Operation was cancelled before completion
    ///
    /// ## Naming
    ///
    /// Named `Outcome` (not `Result`) to avoid collision with `Swift.Result`.
    /// This type represents the kernel-level completion status, distinct from
    /// `IO.Completion.Submit.Result` which carries the buffer back to the caller.
    ///
    /// ## Thread Safety
    ///
    /// `Outcome` is `Sendable` and can cross isolation boundaries.
    public enum Outcome: Sendable, Equatable {
        /// Operation completed successfully.
        case success(Success)

        /// Operation failed with a kernel error.
        case failure(Kernel.Error)

        /// Operation was cancelled.
        case cancellation
    }
}

// MARK: - CustomStringConvertible

extension IO.Completion.Outcome: CustomStringConvertible {
    public var description: String {
        switch self {
        case .success(let success):
            "success(\(success))"
        case .failure(let error):
            "failure(\(error))"
        case .cancellation:
            "cancelled"
        }
    }
}
