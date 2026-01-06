//
//  IO.Completion.Error.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 31/12/2025.
//

public import IO_Primitives
public import Kernel

extension IO.Completion {
    /// Errors from completion-based I/O operations.
    ///
    /// Errors are categorized by source:
    /// - `kernel`: Underlying system call failure
    /// - `operation`: Operation-specific errors (cancelled, timeout, invalid)
    /// - `capability`: Backend capability errors
    /// - `lifecycle`: Queue/driver lifecycle errors
    ///
    /// ## Typed Throws
    ///
    /// Uses `IO.Lifecycle.Error<Error>` as the failure type to combine
    /// lifecycle concerns (shutdown, cancellation) with operational errors.
    ///
    /// ```swift
    /// func submit(...) async throws(Failure) -> Completion
    /// ```
    public enum Error: Swift.Error, Sendable, Equatable {
        /// Underlying kernel/syscall error.
        case kernel(Kernel.Error)

        /// Operation-specific error.
        case operation(Operation)

        /// Capability error (unsupported operation).
        case capability(Capability)

        /// Lifecycle error (queue state).
        case lifecycle(Lifecycle)
    }

    /// Typed failure type for completion operations.
    ///
    /// Combines `IO.Lifecycle.Error` with `IO.Completion.Error` for
    /// complete typed throws coverage.
    public typealias Failure = IO.Lifecycle.Error<Error>
}

// MARK: - CustomStringConvertible

extension IO.Completion.Error: CustomStringConvertible {
    public var description: String {
        switch self {
        case .kernel(let error):
            "kernel(\(error))"
        case .operation(let error):
            "operation(\(error))"
        case .capability(let error):
            "capability(\(error))"
        case .lifecycle(let error):
            "lifecycle(\(error))"
        }
    }
}
