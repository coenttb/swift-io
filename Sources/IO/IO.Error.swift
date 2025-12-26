//
//  IO.Error.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 24/12/2025.
//

extension IO {
    /// Generic error type for async I/O operations.
    ///
    /// This type preserves the specific operation error type while also capturing
    /// I/O infrastructure errors (executor, lane, cancellation).
    ///
    /// ## Usage
    /// Async methods throw `IO.Error<SpecificError>` where `SpecificError` is
    /// the error type from the underlying sync primitive:
    /// ```swift
    /// func read() async throws(IO.Error<ReadError>) -> [UInt8]
    /// ```
    ///
    /// - Note: No Equatable constraint. The Operation type only requires
    ///   `Error & Sendable` for maximum flexibility.
    public enum Error<Operation: Swift.Error & Sendable>: Swift.Error, Sendable {
        /// The operation-specific error from the underlying primitive.
        case operation(Operation)

        /// Handle-related errors.
        case handle(IO.Handle.Error)

        /// Executor-related errors.
        case executor(IO.Executor.Error)

        /// Lane infrastructure errors.
        case lane(IO.Blocking.Failure)

        /// The operation was cancelled.
        case cancelled
    }
}

// MARK: - Mapping

extension IO.Error {
    /// Maps the operation error to a different type.
    ///
    /// Non-operation cases are preserved as-is.
    public func mapOperation<NewOperation: Swift.Error & Sendable>(
        _ transform: (Operation) -> NewOperation
    ) -> IO.Error<NewOperation> {
        switch self {
        case .operation(let op):
            return .operation(transform(op))
        case .handle(let error):
            return .handle(error)
        case .executor(let error):
            return .executor(error)
        case .lane(let failure):
            return .lane(failure)
        case .cancelled:
            return .cancelled
        }
    }
}

// MARK: - CustomStringConvertible

extension IO.Error: CustomStringConvertible {
    public var description: String {
        switch self {
        case .operation(let error):
            return "Operation error: \(error)"
        case .handle(let error):
            return "Handle error: \(error)"
        case .executor(let error):
            return "Executor error: \(error)"
        case .lane(let failure):
            return "Lane failure: \(failure)"
        case .cancelled:
            return "Operation cancelled"
        }
    }
}
