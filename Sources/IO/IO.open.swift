//
//  IO.open.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 07/01/2026.
//

extension IO {
    /// Open a scoped resource with custom close behavior.
    ///
    /// Returns a `Pending` builder that requires `.close(...)` before execution.
    /// This two-state pattern ensures cleanup is never forgotten at compile time.
    ///
    /// ## Usage
    /// ```swift
    /// try await IO.open { Resource.make() }
    ///     .close { $0.teardown() }
    ///     { resource in
    ///         resource.work()
    ///     }
    /// ```
    ///
    /// ## Builder Pattern
    /// The returned `Pending` has no `callAsFunction`. You must call `.close(_:)`
    /// to get a `Ready` builder that can be executed:
    ///
    /// ```swift
    /// let pending = IO.open { File.open(path) }
    /// // pending { ... }  // Compile error - no callAsFunction
    ///
    /// let ready = pending.close { $0.close() }
    /// try await ready { file in file.read() }  // OK
    /// ```
    ///
    /// ## Backend
    /// Uses `IO.Blocking.Lane.shared` for execution.
    ///
    /// - Parameter create: Closure that creates the resource.
    /// - Returns: A `Pending` builder awaiting close specification.
    @inlinable
    public static func open<Resource: ~Copyable & Sendable, CreateError: Swift.Error & Sendable>(
        _ create: @Sendable @escaping () throws(CreateError) -> Resource
    ) -> IO.Scope.Pending<IO.Blocking.Lane, Resource, CreateError> {
        IO.Blocking.Lane.shared.open(create)
    }

    /// Open a scoped resource with inferred close behavior.
    ///
    /// For resources conforming to `IO.Closable`, the `close()` method is
    /// called automatically after the body completes (or throws).
    ///
    /// ## Usage
    /// ```swift
    /// // File: IO.Closable with CloseError == Never
    /// try await IO.open { File.open(path) } { file in
    ///     file.read(into: buffer)
    /// }
    /// // file.close() called automatically
    /// ```
    ///
    /// ## Error Composition
    /// The full error type is:
    /// ```
    /// IO.Lifecycle.Error<IO.Scope.Failure<CreateError, BodyError, Resource.CloseError>>
    /// ```
    ///
    /// When `Resource.CloseError == Never`, the `.close(...)` case is statically
    /// unreachable, enabling compiler optimization.
    ///
    /// ## Backend
    /// Uses `IO.Blocking.Lane.shared` for execution.
    ///
    /// - Parameters:
    ///   - create: Closure that creates the resource.
    ///   - body: Closure that uses the resource.
    /// - Returns: The body's return value.
    @inlinable
    public static func open<
        Resource: IO.Closable & Sendable,
        T: Sendable,
        CreateError: Swift.Error & Sendable,
        BodyError: Swift.Error & Sendable
    >(
        _ create: @Sendable @escaping () throws(CreateError) -> Resource,
        _ body: @escaping @Sendable (inout Resource) throws(BodyError) -> T
    ) async throws(IO.Lifecycle.Error<IO.Scope.Failure<CreateError, BodyError, Resource.CloseError>>) -> T {
        try await IO.Blocking.Lane.shared.open(create, body)
    }
}
