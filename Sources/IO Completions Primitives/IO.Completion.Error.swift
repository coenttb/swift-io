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

        // MARK: - Operation Errors

        /// Operation-specific errors.
        public enum Operation: Swift.Error, Sendable, Equatable {
            /// The operation was cancelled.
            case cancelled

            /// The operation timed out.
            case timeout

            /// Invalid operation submission.
            ///
            /// The operation parameters were invalid or inconsistent.
            case invalidSubmission
        }

        // MARK: - Capability Errors

        /// Capability errors.
        public enum Capability: Swift.Error, Sendable, Equatable {
            /// The operation kind is not supported by this backend.
            case unsupportedKind(IO.Completion.Kind)

            /// No suitable backend is available.
            case backendUnavailable
        }

        // MARK: - Lifecycle Errors

        /// Lifecycle errors.
        public enum Lifecycle: Swift.Error, Sendable, Equatable {
            /// The queue is shutting down.
            case shutdownInProgress

            /// The queue has been closed.
            case queueClosed
        }
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

extension IO.Completion.Error.Operation: CustomStringConvertible {
    public var description: String {
        switch self {
        case .cancelled: "cancelled"
        case .timeout: "timeout"
        case .invalidSubmission: "invalidSubmission"
        }
    }
}

extension IO.Completion.Error.Capability: CustomStringConvertible {
    public var description: String {
        switch self {
        case .unsupportedKind(let kind): "unsupportedKind(\(kind))"
        case .backendUnavailable: "backendUnavailable"
        }
    }
}

extension IO.Completion.Error.Lifecycle: CustomStringConvertible {
    public var description: String {
        switch self {
        case .shutdownInProgress: "shutdownInProgress"
        case .queueClosed: "queueClosed"
        }
    }
}
