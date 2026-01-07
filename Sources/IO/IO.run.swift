//
//  IO.run.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 07/01/2026.
//

extension IO {
    /// Execute blocking work on the shared lane.
    ///
    /// This is the simplest entry point for blocking I/O. The system
    /// uses dedicated OS threads to prevent blocking Swift's cooperative
    /// thread pool.
    ///
    /// ## Usage
    /// ```swift
    /// // Simple blocking work
    /// let data = try await IO.run {
    ///     FileHandle.read(path)
    /// }
    ///
    /// // With deadline
    /// let result = try await IO.run(deadline: .now + .seconds(5)) {
    ///     socket.connect()
    /// }
    /// ```
    ///
    /// ## Error Handling
    /// - Operation errors are returned in a Result
    /// - Lane errors (shutdown, cancellation, timeout) are wrapped in `IO.Lifecycle.Error`
    ///
    /// ## Backend
    /// Uses `IO.Blocking.Lane.shared`, which provides dedicated OS threads.
    /// For advanced control, use `IO.Blocking.Lane.threads(options)` directly.
    ///
    /// - Parameters:
    ///   - deadline: Optional deadline for the operation.
    ///   - operation: The blocking operation to execute.
    /// - Returns: A Result containing either the operation result or the operation error.
    /// - Throws: Lifecycle error for lane failures (shutdown, cancellation, timeout).
    @inlinable
    public static func run<T: Sendable, E: Swift.Error & Sendable>(
        deadline: IO.Blocking.Deadline? = nil,
        _ operation: @Sendable @escaping () throws(E) -> T
    ) async throws(IO.Lifecycle.Error<IO.Blocking.Lane.Error>) -> Result<T, E> {
        try await IO.Blocking.Lane.shared.run(deadline: deadline, operation)
    }

    /// Execute non-throwing blocking work on the shared lane.
    ///
    /// Convenience overload for operations that cannot fail.
    ///
    /// ## Usage
    /// ```swift
    /// let hash = try await IO.run {
    ///     computeExpensiveHash(data)
    /// }
    /// ```
    ///
    /// - Parameters:
    ///   - deadline: Optional deadline for the operation.
    ///   - operation: The non-throwing blocking operation.
    /// - Returns: The operation result.
    /// - Throws: Lifecycle error for lane failures (shutdown, cancellation, timeout).
    @inlinable
    public static func run<T: Sendable>(
        deadline: IO.Blocking.Deadline? = nil,
        _ operation: @Sendable @escaping () -> T
    ) async throws(IO.Lifecycle.Error<IO.Blocking.Lane.Error>) -> T {
        try await IO.Blocking.Lane.shared.run(deadline: deadline, operation)
    }
}
