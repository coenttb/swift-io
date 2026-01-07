//
//  IO.Blocking.Lane.open.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 07/01/2026.
//

// MARK: - Custom Close Builder

extension IO.Blocking.Lane {
    /// Open a scoped resource with custom close behavior.
    ///
    /// Returns a `Pending` builder that requires `.close(...)` before execution.
    ///
    /// ## Usage
    ///
    /// ```swift
    /// try await lane.open { Resource.make() }
    ///     .close { $0.teardown() }
    ///     { resource in
    ///         resource.work()
    ///     }
    /// ```
    ///
    /// ## Two-State Builder
    ///
    /// The returned `Pending` has no `callAsFunction`. You must call `.close(_:)`
    /// to get a `Ready` builder that can be executed. This prevents forgetting
    /// cleanup at compile time.
    ///
    /// - Parameter create: Closure that creates the resource.
    /// - Returns: A `Pending` builder awaiting close specification.
    @inlinable
    public func open<Resource: ~Copyable & Sendable, CreateError: Swift.Error & Sendable>(
        _ create: @Sendable @escaping () throws(CreateError) -> Resource
    ) -> IO.Scope.Pending<Self, Resource, CreateError> {
        IO.Scope.Pending(lane: self, create: create)
    }
}

// MARK: - Inferred Close (IO.Closable)

extension IO.Blocking.Lane {
    /// Open a scoped resource with inferred close behavior.
    ///
    /// For resources conforming to `IO.Closable`, the `close()` method is
    /// called automatically after the body completes (or throws).
    ///
    /// ## Usage
    ///
    /// ```swift
    /// // File: IO.Closable with CloseError == Never
    /// try await lane.open { File.open(path) } { file in
    ///     file.read(into: buffer)
    /// }
    /// // file.close() called automatically
    /// ```
    ///
    /// ## Error Composition
    ///
    /// The full error type is:
    /// ```
    /// IO.Lifecycle.Error<IO.Scope.Failure<CreateError, BodyError, Resource.CloseError>>
    /// ```
    ///
    /// When `Resource.CloseError == Never`, the `.close(...)` case is statically
    /// unreachable, enabling compiler optimization.
    ///
    /// - Parameters:
    ///   - create: Closure that creates the resource.
    ///   - body: Closure that uses the resource.
    /// - Returns: The body's return value.
    @inlinable
    public func open<
        Resource: IO.Closable & Sendable,
        T: Sendable,
        CreateError: Swift.Error & Sendable,
        BodyError: Swift.Error & Sendable
    >(
        _ create: @Sendable @escaping () throws(CreateError) -> Resource,
        _ body: @escaping @Sendable (inout Resource) throws(BodyError) -> T
    ) async throws(IO.Lifecycle.Error<IO.Scope.Failure<CreateError, BodyError, Resource.CloseError>>) -> T {
        let pending: IO.Scope.Pending<Self, Resource, CreateError> = self.open(create)
        let closeFn: @Sendable (consuming Resource) throws(Resource.CloseError) -> Void = { resource in
            try resource.close()
        }
        let ready: IO.Scope.Ready<Self, Resource, CreateError, Resource.CloseError> = pending.close(closeFn)
        return try await ready(body)
    }
}
