//
//  IO.Lifecycle.Error.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 28/12/2025.
//

public import Synchronization

extension IO {
    /// Lifecycle state for Pool and Lane operations.
    ///
    /// This enum enables atomic lifecycle checks without actor isolation,
    /// allowing `run()` to bypass the actor hop for improved throughput.
    ///
    /// ## Memory Ordering
    /// - Readers use `.acquiring` to see effects of shutdown
    /// - Writers use `.releasing` to publish state changes
    public enum Lifecycle: UInt8, Sendable, AtomicRepresentable {
        /// Running and accepting new work.
        case running = 0
        /// Shutdown has been initiated; new work is rejected.
        case shutdownInProgress = 1
        /// Shutdown is complete; resources are torn down.
        case shutdownComplete = 2
    }
}

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

        /// A leaf error (operational failure).
        case failure(E)
    }
}

// MARK: - CustomStringConvertible

extension IO.Lifecycle.Error: CustomStringConvertible {
    public var description: String {
        switch self {
        case .shutdownInProgress:
            return "Shutdown in progress"
        case .cancelled:
            return "Cancelled"
        case .failure(let e):
            return "Failure: \(e)"
        }
    }
}
