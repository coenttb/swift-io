//
//  IO.Scope.Ready.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 07/01/2026.
//

extension IO.Scope {
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
    /// try await lane.open { Resource.make() }
    ///     .close { $0.teardown() }
    ///     { resource in
    ///         resource.work()
    ///     }
    /// ```
    ///
    /// ## Error Handling
    ///
    /// All errors are composed into `IO.Lifecycle.Error<IO.Scope.Failure<...>>`:
    /// - Lifecycle wrapper handles shutdown/cancellation/timeout
    /// - Scope.Failure handles create/body/close operational errors
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

extension IO.Scope.Ready where L == IO.Blocking.Lane, Resource: Sendable {
    /// Execute the scoped resource lifecycle.
    ///
    /// ## Lifecycle
    ///
    /// 1. Create resource via `create()`
    /// 2. Execute `body` with `inout` access
    /// 3. Close resource via `close()` (always, even if body throws)
    /// 4. Return result or throw composed error
    ///
    /// ## Error Composition
    ///
    /// - Create failure → `.failure(.create(E))`
    /// - Body failure, close success → `.failure(.body(E))`
    /// - Body success, close failure → `.failure(.close(E))`
    /// - Body failure, close failure → `.failure(.bodyAndClose(...))`
    /// - Lane infrastructure failure → `.failure(.lane(E))`
    /// - Shutdown/cancellation/timeout → lifecycle-level error
    ///
    /// - Parameter body: Closure that uses the resource.
    /// - Returns: The body's return value.
    /// - Throws: `IO.Lifecycle.Error<IO.Scope.Failure<CreateError, BodyError, CloseError>>`
    @inlinable
    public func callAsFunction<T: Sendable, BodyError: Swift.Error & Sendable>(
        _ body: @escaping @Sendable (inout Resource) throws(BodyError) -> T
    ) async throws(IO.Lifecycle.Error<IO.Scope.Failure<CreateError, BodyError, CloseError>>) -> T {
        typealias Failure = IO.Scope.Failure<CreateError, BodyError, CloseError>
        typealias LaneError = IO.Lifecycle.Error<IO.Blocking.Lane.Error>

        let create = self.create
        let close = self.close

        // Build the operation that runs on the lane
        // This closure is non-throwing and returns Result to preserve typed errors
        let operation: @Sendable () -> Result<T, Failure> = {
            // Create resource
            var resource: Resource
            do {
                resource = try create()
            } catch let e as CreateError {
                return .failure(.create(e))
            } catch {
                // Should never happen - create() only throws CreateError
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
                // Should never happen - body() only throws BodyError
                fatalError("Unexpected error type from body()")
            }

            // Close resource (always)
            var closeError: CloseError? = nil
            do {
                try close(consume resource)
            } catch let e as CloseError {
                closeError = e
            } catch {
                // Should never happen - close() only throws CloseError
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

        // Run on lane and transform errors
        let laneResult: Result<Result<T, Failure>, LaneError>
        do {
            let inner = try await lane.run(deadline: nil, operation)
            laneResult = .success(inner)
        } catch {
            laneResult = .failure(error)
        }

        // Transform lane errors to scope lifecycle errors
        let result: Result<T, Failure>
        switch laneResult {
        case .success(let inner):
            result = inner
        case .failure(let laneError):
            switch laneError {
            case .shutdownInProgress:
                throw IO.Lifecycle.Error<Failure>.shutdownInProgress
            case .cancellation:
                throw IO.Lifecycle.Error<Failure>.cancellation
            case .timeout:
                throw IO.Lifecycle.Error<Failure>.timeout
            case .failure(let innerLaneError):
                throw IO.Lifecycle.Error<Failure>.failure(.lane(innerLaneError))
            }
        }

        switch result {
        case .success(let value):
            return value
        case .failure(let error):
            throw .failure(error)
        }
    }
}
