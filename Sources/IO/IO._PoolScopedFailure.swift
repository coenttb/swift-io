//
//  IO._PoolScopedFailure.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 07/01/2026.
//

// MARK: - Hoisted Error Type (Workaround for Swift compiler bug #86347)
//
// This error type is hoisted to module level (not nested in generic IO.Pool<Resource>)
// to work around a Swift 6.2 compiler crash when combining:
// - Generic container type (Box<T>)
// - Nested error type inside that generic
// - Async typed throws
//
// The nested IO.Pool<Resource>.Scoped.Failure is a typealias to this type.
// When Swift bug #86347 is fixed, move this definition into IO.Pool.Scoped.Failure
// and remove this file.

extension IO {
    /// Operational errors from scoped pool operations.
    ///
    /// - Note: This is an internal implementation type. Use `IO.Pool.Scoped.Failure` instead.
    ///
    /// ## Design
    ///
    /// This single-generic error captures failures during pool scoped operations:
    /// - `acquire`: Failed to acquire a resource from the pool
    /// - `body`: User code threw during resource use
    /// - `release`: Failed to release the resource back to the pool
    /// - `bodyAndRelease`: Both body and release failed
    ///
    /// ## Composition with IO.Lifecycle.Error
    ///
    /// This type is wrapped in `IO.Lifecycle.Error` for full typed throws:
    /// ```swift
    /// throws(IO.Lifecycle.Error<IO.Pool.Scoped.Failure<BodyError>>)
    /// ```
    ///
    /// ## Pool.Error vs Body Error
    ///
    /// Pool infrastructure errors (`acquire`, `release`) use `IO._PoolError`.
    /// User code errors (`body`) use the generic `Body` parameter.
    /// This keeps infrastructure errors normalized while preserving user types.
    ///
    /// ## Workaround Note
    ///
    /// This type is intentionally hoisted to `IO._PoolScopedFailure` (not nested in
    /// `IO.Pool<Resource>.Scoped`) due to Swift compiler bug #86347. The public API
    /// remains `IO.Pool<Resource>.Scoped.Failure` via typealias.
    public enum _PoolScopedFailure<Body: Swift.Error & Sendable>: Swift.Error, Sendable {
        /// Failed to acquire a resource from the pool.
        case acquire(IO._PoolError)

        /// User body code threw an error.
        case body(Body)

        /// Failed to release the resource back to the pool.
        case release(IO._PoolError)

        /// Both body and release failed.
        ///
        /// Body error is primary; release error is preserved for diagnostics.
        case bodyAndRelease(body: Body, release: IO._PoolError)
    }
}

// MARK: - Equatable

extension IO._PoolScopedFailure: Equatable where Body: Equatable {}

// MARK: - CustomStringConvertible

extension IO._PoolScopedFailure: CustomStringConvertible {
    public var description: String {
        switch self {
        case .acquire(let error):
            "acquire(\(error))"
        case .body(let error):
            "body(\(error))"
        case .release(let error):
            "release(\(error))"
        case .bodyAndRelease(let body, let release):
            "bodyAndRelease(body: \(body), release: \(release))"
        }
    }
}
