//
//  IO.Ready.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 07/01/2026.
//

public import IO_Blocking

extension IO {
    /// Builder state ready for execution.
    ///
    /// ## Two-State Builder Pattern
    ///
    /// `Ready` represents the final state where:
    /// - Lane is captured
    /// - Create closure is captured
    /// - Close closure is captured
    ///
    /// This state has `callAsFunction` - execution is now allowed.
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
    /// ## Error Handling
    ///
    /// All errors are composed into `IO.Failure.Scope<IO.Lane.Error, ...>`:
    /// - Domain case handles lane infrastructure failures
    /// - Create/body/close cases handle operational errors
    ///
    /// ## ~Copyable Resources
    ///
    /// Body receives `inout Resource` to prevent escape while allowing mutation.
    /// Close receives `consuming Resource` to take ownership.
    public struct Ready<
        L: Sendable,
        Resource: ~Copyable,
        CreateError: Swift.Error & Sendable,
        CloseError: Swift.Error & Sendable
    >: Sendable {
        @usableFromInline
        let lane: L

        @usableFromInline
        let create: @Sendable () throws(CreateError) -> Resource

        @usableFromInline
        let close: @Sendable (consuming Resource) throws(CloseError) -> Void

        @inlinable
        init(
            lane: L,
            create: @escaping @Sendable () throws(CreateError) -> Resource,
            close: @escaping @Sendable (consuming Resource) throws(CloseError) -> Void
        ) {
            self.lane = lane
            self.create = create
            self.close = close
        }
    }
}

// MARK: - IO.Blocking.Lane Execution

extension IO.Ready where L == IO.Blocking.Lane, Resource: Sendable {
    /// Execute the scoped resource lifecycle.
    ///
    /// ## Lifecycle
    ///
    /// 1. Create resource via `create()`
    /// 2. Execute `body` with `inout` access
    /// 3. Close resource via `close()` (always, even if body throws)
    /// 4. Return result or throw composed error
    ///
    /// ## Error Handling
    ///
    /// ```swift
    /// do {
    ///     try await IO.open { try File.open(path) }
    ///         .close { $0.close() }
    ///         { file in try file.read() }
    /// } catch {
    ///     switch error {
    ///     case .domain(.timeout): // lane timeout
    ///     case .create(let e): // open failed
    ///     case .body(let e): // read failed
    ///     case .close(let e): // close failed
    ///     case .bodyAndClose(let b, let c): // both failed
    ///     }
    /// }
    /// ```
    ///
    /// - Parameter body: Closure that uses the resource.
    /// - Returns: The body's return value.
    /// - Throws: `IO.Failure.Scope<IO.Lane.Error, CreateError, BodyError, CloseError>`
    @inlinable
    public func callAsFunction<T: Sendable, BodyError: Swift.Error & Sendable>(
        _ body: @escaping @Sendable (inout Resource) throws(BodyError) -> T
    ) async throws(IO.Failure.Scope<IO.Lane.Error, CreateError, BodyError, CloseError>) -> T {
        typealias Failure = IO.Failure.Scope<IO.Lane.Error, CreateError, BodyError, CloseError>

        let create = self.create
        let close = self.close

        // Build the operation that runs on the lane
        let operation: @Sendable () -> Result<T, IO._ScopeOperationFailure<CreateError, BodyError, CloseError>> = {
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
            var closeError: CloseError? = nil
            do {
                try close(consume resource)
            } catch let e as CloseError {
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
        let result: Result<T, IO._ScopeOperationFailure<CreateError, BodyError, CloseError>>
        do {
            result = try await lane.run(deadline: nil, operation)
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

