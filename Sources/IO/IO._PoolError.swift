//
//  IO._PoolError.swift
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
// The nested IO.Pool<Resource>.Error is a typealias to this type.
// When Swift bug #86347 is fixed, move this definition into IO.Pool.Error
// and remove this file.

extension IO {
    /// Infrastructure errors from pool operations.
    ///
    /// - Note: This is an internal implementation type. Use `IO.Pool.Error` instead.
    ///
    /// ## Workaround Note
    ///
    /// This type is intentionally hoisted to `IO._PoolError` (not nested in
    /// `IO.Pool<Resource>`) due to Swift compiler bug #86347. The public API
    /// remains `IO.Pool<Resource>.Error` via typealias.
    public enum _PoolError: Swift.Error, Sendable, Equatable {
        /// The pool is shutting down.
        ///
        /// New operations are rejected. In-flight operations may complete.
        case shutdown

        /// All resources are in use and no more can be created.
        ///
        /// Retry after a resource is released.
        case exhausted

        /// Acquisition timed out waiting for a resource.
        case timeout

        /// The operation was cancelled.
        case cancelled

        /// The ID belongs to a different pool.
        ///
        /// Each pool has a unique scope. IDs from one pool cannot be
        /// used with another pool.
        case scopeMismatch

        /// The ID is not valid.
        ///
        /// The resource was already released or never acquired.
        case invalidID
    }
}

// MARK: - CustomStringConvertible

extension IO._PoolError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .shutdown: "shutdown"
        case .exhausted: "exhausted"
        case .timeout: "timeout"
        case .cancelled: "cancelled"
        case .scopeMismatch: "scopeMismatch"
        case .invalidID: "invalidID"
        }
    }
}
