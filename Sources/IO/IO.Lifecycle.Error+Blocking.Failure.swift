//
//  IO.Lifecycle.Error+Blocking.Failure.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 29/12/2025.
//

// MARK: - Lane Failure → IO.Error (infrastructure wrapper)

extension IO.Error {
    /// Creates an IO.Error from a lane failure.
    ///
    /// All lane failures map to `.lane(...)`.
    ///
    /// ## Usage
    /// ```swift
    /// throw IO.Lifecycle.Error.failure(IO.Error(laneFailure))
    /// ```
    @inlinable
    public init(_ failure: IO.Blocking.Failure) {
        switch failure {
        case .shutdown, .cancellationRequested:
            // These should be handled at the Lifecycle level, not here.
            // But we need to handle all cases - map to internal invariant.
            self = .lane(.internalInvariantViolation)
        case .queueFull:
            self = .lane(.queueFull)
        case .deadlineExceeded:
            self = .lane(.deadlineExceeded)
        case .overloaded:
            self = .lane(.overloaded)
        case .internalInvariantViolation:
            self = .lane(.internalInvariantViolation)
        }
    }
}

// MARK: - Lane Failure → Lifecycle Error (with IO.Error<Leaf> wrapper)

extension IO.Lifecycle.Error {
    /// Creates a lifecycle error from a lane failure when E is IO.Error<Leaf>.
    ///
    /// Maps lane infrastructure failures to the appropriate lifecycle or operational error:
    /// - `.shutdown` → `.shutdownInProgress`
    /// - `.cancellationRequested` → `.cancelled`
    /// - All others → `.failure(.lane(...))`
    ///
    /// ## Usage
    /// ```swift
    /// do {
    ///     result = try await lane.run(operation)
    /// } catch {
    ///     throw IO.Lifecycle.Error<IO.Error<MyError>>(error)
    /// }
    /// ```
    @inlinable
    public init<Leaf: Swift.Error & Sendable>(
        _ failure: IO.Blocking.Failure
    ) where E == IO.Error<Leaf> {
        switch failure {
        case .shutdown:
            self = .shutdownInProgress
        case .cancellationRequested:
            self = .cancelled
        case .queueFull:
            self = .failure(.lane(.queueFull))
        case .deadlineExceeded:
            self = .failure(.lane(.deadlineExceeded))
        case .overloaded:
            self = .failure(.lane(.overloaded))
        case .internalInvariantViolation:
            self = .failure(.lane(.internalInvariantViolation))
        }
    }
}

// MARK: - Lane Failure → Lifecycle Error (with Transaction.Error<E> wrapper)

extension IO.Lifecycle.Error {
    /// Creates a lifecycle error from a lane failure when E is Transaction.Error<Body>.
    ///
    /// Maps lane infrastructure failures to the appropriate lifecycle or operational error:
    /// - `.shutdown` → `.shutdownInProgress`
    /// - `.cancellationRequested` → `.cancelled`
    /// - All others → `.failure(.lane(...))`
    @inlinable
    public init<Body: Swift.Error & Sendable>(
        _ failure: IO.Blocking.Failure
    ) where E == IO.Executor.Transaction.Error<Body> {
        switch failure {
        case .shutdown:
            self = .shutdownInProgress
        case .cancellationRequested:
            self = .cancelled
        case .queueFull:
            self = .failure(.lane(.queueFull))
        case .deadlineExceeded:
            self = .failure(.lane(.deadlineExceeded))
        case .overloaded:
            self = .failure(.lane(.overloaded))
        case .internalInvariantViolation:
            self = .failure(.lane(.internalInvariantViolation))
        }
    }
}

// MARK: - Lane Failure → Lifecycle Error (direct IO.Blocking.Error)

extension IO.Lifecycle.Error where E == IO.Blocking.Error {
    /// Creates a lifecycle error from a lane failure.
    ///
    /// Maps lane infrastructure failures to the appropriate lifecycle or operational error:
    /// - `.shutdown` → `.shutdownInProgress`
    /// - `.cancellationRequested` → `.cancelled`
    /// - All others → `.failure(...)`
    ///
    /// ## Usage
    /// ```swift
    /// do {
    ///     return try await lane.run(operation)
    /// } catch {
    ///     throw IO.Lifecycle.Error(error)
    /// }
    /// ```
    @inlinable
    public init(_ failure: IO.Blocking.Failure) {
        switch failure {
        case .shutdown:
            self = .shutdownInProgress
        case .cancellationRequested:
            self = .cancelled
        case .queueFull:
            self = .failure(.queueFull)
        case .deadlineExceeded:
            self = .failure(.deadlineExceeded)
        case .overloaded:
            self = .failure(.overloaded)
        case .internalInvariantViolation:
            self = .failure(.internalInvariantViolation)
        }
    }
}
