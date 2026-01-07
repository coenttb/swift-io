//
//  IO.Pool.Scoped.Failure.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 07/01/2026.
//

extension IO.Pool.Scoped where Resource: ~Copyable & Sendable {
    /// Operational errors from scoped pool operations.
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
    /// Pool infrastructure errors (`acquire`, `release`) use `IO.Pool.Error`.
    /// User code errors (`body`) use the generic `Body` parameter.
    /// This keeps infrastructure errors normalized while preserving user types.
    ///
    /// ## Implementation Note
    ///
    /// This is a typealias to `IO._PoolScopedFailure` to work around Swift compiler
    /// bug #86347. When the bug is fixed, the definition can be moved here.
    public typealias Failure<Body: Swift.Error & Sendable> = IO._PoolScopedFailure<Body>
}
