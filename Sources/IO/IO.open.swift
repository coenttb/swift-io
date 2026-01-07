//
//  IO.open.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 07/01/2026.
//

public import IO_Blocking
public import IO_Blocking_Threads

extension IO {
    /// Open a scoped resource with custom close behavior.
    ///
    /// Returns a `Pending` builder that requires `.close(...)` before execution.
    /// This two-state pattern ensures cleanup is never forgotten at compile time.
    ///
    /// ## Usage
    ///
    /// ```swift
    /// try await IO.open { Resource.make() }
    ///     .close { $0.teardown() }
    ///     { resource in
    ///         resource.work()
    ///     }
    /// ```
    ///
    /// ## Builder Pattern
    ///
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
    /// - Parameter create: Closure that creates the resource.
    /// - Returns: A `Pending` builder awaiting close specification.
    @inlinable
    public static func open<Resource: ~Copyable & Sendable, CreateError: Swift.Error & Sendable>(
        _ create: @Sendable @escaping () throws(CreateError) -> Resource
    ) -> IO.Pending<IO.Blocking.Lane, Resource, CreateError> {
        IO.Blocking.Lane.shared.open(create)
    }

    /// Open a scoped resource on a specific lane with custom close behavior.
    ///
    /// - Parameters:
    ///   - lane: The lane to execute on.
    ///   - create: Closure that creates the resource.
    /// - Returns: A `Pending` builder awaiting close specification.
    @inlinable
    public static func open<Resource: ~Copyable & Sendable, CreateError: Swift.Error & Sendable>(
        on lane: IO.Lane,
        _ create: @Sendable @escaping () throws(CreateError) -> Resource
    ) -> IO.Pending<IO.Blocking.Lane, Resource, CreateError> {
        lane._backing.open(create)
    }

    /// Open a scoped resource with inferred close behavior.
    ///
    /// For resources conforming to `IO.Closable`, the `close()` method is
    /// called automatically after the body completes (or throws).
    ///
    /// ## Usage
    ///
    /// ```swift
    /// // File: IO.Closable with CloseError == Never
    /// try await IO.open { File.open(path) } body: { file in
    ///     file.read(into: buffer)
    /// }
    /// // file.close() called automatically
    /// ```
    ///
    /// ## Error Handling
    ///
    /// ```swift
    /// do {
    ///     try await IO.open { try File.open(path) } body: { file in
    ///         try file.read()
    ///     }
    /// } catch {
    ///     switch error {
    ///     case .domain(.timeout): // lane timeout
    ///     case .create(let e): // file open failed
    ///     case .body(let e): // read failed
    ///     case .close(let e): // close failed
    ///     case .bodyAndClose(let b, let c): // both failed
    ///     }
    /// }
    /// ```
    ///
    /// - Parameters:
    ///   - lane: The lane to execute on (default: `.shared`).
    ///   - deadline: Optional deadline for acceptance.
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
        on lane: IO.Lane = .shared,
        deadline: IO.Deadline? = nil,
        _ create: @Sendable @escaping () throws(CreateError) -> Resource,
        body: @escaping @Sendable (inout Resource) throws(BodyError) -> T
    ) async throws(IO.Failure.Scope<IO.Lane.Error, CreateError, BodyError, Resource.CloseError>) -> T {
        typealias Failure = IO.Failure.Scope<IO.Lane.Error, CreateError, BodyError, Resource.CloseError>

        let close: @Sendable (consuming Resource) throws(Resource.CloseError) -> Void = { resource in
            try resource.close()
        }

        // Build the operation that runs on the lane
        let operation: @Sendable () -> Result<T, _ScopeOperationFailure<CreateError, BodyError, Resource.CloseError>> = {
            // Create resource
            var resource: Resource
            do {
                resource = try create()
            } catch let e as CreateError {
                return .failure(.create(e))
            } catch {
                fatalError("Unexpected error type from create()")
            }

            // Execute body
            var bodyError: BodyError? = nil
            var value: T? = nil
            do {
                value = try body(&resource)
            } catch let e as BodyError {
                bodyError = e
            } catch {
                fatalError("Unexpected error type from body()")
            }

            // Close resource (always)
            var closeError: Resource.CloseError? = nil
            do {
                try close(consume resource)
            } catch let e as Resource.CloseError {
                closeError = e
            } catch {
                fatalError("Unexpected error type from close()")
            }

            // Compose result
            switch (bodyError, closeError) {
            case (nil, nil):
                return .success(value!)
            case (let body?, nil):
                return .failure(.body(body))
            case (nil, let close?):
                return .failure(.close(close))
            case (let body?, let close?):
                return .failure(.bodyAndClose(body: body, close: close))
            }
        }

        // Run on lane
        let result: Result<T, _ScopeOperationFailure<CreateError, BodyError, Resource.CloseError>>
        do {
            result = try await lane._backing.run(deadline: deadline, operation)
        } catch {
            throw .domain(IO.Lane.Error(from: error))
        }

        switch result {
        case .success(let value):
            return value
        case .failure(let error):
            switch error {
            case .create(let e): throw .create(e)
            case .body(let e): throw .body(e)
            case .close(let e): throw .close(e)
            case .bodyAndClose(let b, let c): throw .bodyAndClose(body: b, close: c)
            }
        }
    }
}

// MARK: - Internal Helper

extension IO {
    /// Internal helper for scope operation errors (without domain).
    @usableFromInline
    internal enum _ScopeOperationFailure<
        Create: Swift.Error & Sendable,
        Body: Swift.Error & Sendable,
        Close: Swift.Error & Sendable
    >: Swift.Error, Sendable {
        case create(Create)
        case body(Body)
        case close(Close)
        case bodyAndClose(body: Body, close: Close)
    }
}
