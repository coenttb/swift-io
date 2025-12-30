//
//  IO.Lifecycle.Error.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 28/12/2025.
//

extension IO.Lifecycle {
    /// Lifecycle wrapper for async I/O operations.
    ///
    /// This is the **only** place where shutdown and cancellation can exist
    /// in the public API. All other error types (leaf errors, infrastructure errors)
    /// are wrapped in `.failure(E)`.
    ///
    /// ## Design
    /// - Shutdown and cancellation are lifecycle concerns, not operational failures.
    /// - By wrapping all leaf errors in `.failure(E)`, we make wrong-category
    ///   errors statically unrepresentable.
    /// - This type is intentionally minimal (no mapping helpers) to keep
    ///   layer boundaries clear.
    ///
    /// ## Usage
    /// ```swift
    /// func run<T, E>(...) async throws(IO.Lifecycle.Error<IO.Error<E>>) -> T
    /// ```
    public enum Error<E: Swift.Error & Sendable>: Swift.Error, Sendable {
        /// The executor/lane is shutting down.
        /// New operations are rejected.
        case shutdownInProgress

        /// The operation was cancelled before completion.
        case cancelled

        /// The operation timed out before completion.
        ///
        /// This occurs when a deadline expires before the operation completes.
        /// Unlike cancellation, timeout is deterministic based on wall-clock time.
        case timeout

        /// A leaf error (operational failure).
        case failure(E)
    }
}

extension IO.Lifecycle.Error: CustomStringConvertible {
    public var description: String {
        switch self {
        case .shutdownInProgress:
            return "Shutdown in progress"
        case .cancelled:
            return "Cancelled"
        case .timeout:
            return "Timeout"
        case .failure(let e):
            return "Failure: \(e)"
        }
    }
}
