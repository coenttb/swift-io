//
//  IO.Error.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 24/12/2025.
//

extension IO {
    /// IO domain failure sum type for operations.
    ///
    /// This type preserves the specific leaf error type while also capturing
    /// I/O infrastructure errors (executor, handle, lane).
    ///
    /// ## Design
    /// - Lifecycle concerns (shutdown, cancellation) are NOT in this type.
    /// - They are surfaced through `IO.Lifecycle.Error` at the Pool boundary.
    /// - This ensures wrong-category errors are statically unrepresentable.
    ///
    /// ## Usage
    /// Pool methods throw `IO.Lifecycle.Error<IO.Error<LeafError>>`:
    /// ```swift
    /// func read() async throws(IO.Lifecycle.Error<IO.Error<ReadError>>) -> [UInt8]
    /// ```
    ///
    /// ## No Equatable Constraint
    /// The Leaf type only requires `Error & Sendable` - no `Equatable` constraint.
    /// This enables maximum flexibility.
    public enum Error<Leaf: Swift.Error & Sendable>: Swift.Error, Sendable {
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
    public func mapLeaf<NewLeaf: Swift.Error & Sendable>(
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
    public var description: String {
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
