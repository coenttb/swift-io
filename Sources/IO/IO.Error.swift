//
//  IO.Error.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 24/12/2025.
//

import IO_Blocking

// MARK: - Internal Composition Type

extension IO {
    /// Internal infrastructure error type for executor operations.
    ///
    /// This type preserves the specific leaf error type while also capturing
    /// I/O infrastructure errors (executor, handle, lane).
    ///
    /// - Note: This is an internal implementation type. The public API uses
    ///   `IO.Failure.Work` and `IO.Failure.Scope` envelopes instead.
    ///
    /// ## Design
    /// - Lifecycle concerns (shutdown, cancellation) are NOT in this type.
    /// - They are surfaced through `IO.Lifecycle.Error` at the internal boundary.
    /// - The public surface translates to `IO.Failure.*` envelopes.
    internal enum Error<Leaf: Swift.Error & Sendable>: Swift.Error, Sendable {
        /// The leaf error from the underlying operation.
        case leaf(Leaf)

        /// Handle-related errors.
        case handle(IO.Handle.Error)

        /// Executor-related errors.
        case executor(IO.Executor.Error)

        /// Blocking subsystem errors (excludes lifecycle concerns).
        case blocking(IO.Blocking.Error)
    }
}

// MARK: - Mapping

extension IO.Error {
    /// Maps the leaf error to a different type.
    ///
    /// Non-leaf cases are preserved as-is.
    internal func mapLeaf<NewLeaf: Swift.Error & Sendable>(
        _ transform: (Leaf) -> NewLeaf
    ) -> IO.Error<NewLeaf> {
        switch self {
        case .leaf(let e):
            return .leaf(transform(e))
        case .handle(let error):
            return .handle(error)
        case .executor(let error):
            return .executor(error)
        case .blocking(let error):
            return .blocking(error)
        }
    }
}

// MARK: - CustomStringConvertible

extension IO.Error: CustomStringConvertible {
    internal var description: String {
        switch self {
        case .leaf(let error):
            return "Leaf error: \(error)"
        case .handle(let error):
            return "Handle error: \(error)"
        case .executor(let error):
            return "Executor error: \(error)"
        case .blocking(let error):
            return "Blocking error: \(error)"
        }
    }
}
