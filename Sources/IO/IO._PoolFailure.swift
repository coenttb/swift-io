//
//  IO._PoolFailure.swift
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
// The nested IO.Pool<Resource>.Failure is a typealias to this type.
// When Swift bug #86347 is fixed, move this definition into IO.Pool
// and remove this file.

extension IO {
    /// Composed error for pool scoped operations.
    ///
    /// - Note: This is an internal implementation type. Use `IO.Pool.Failure` instead.
    ///
    /// ## Design
    ///
    /// This two-case error cleanly separates pool infrastructure failures from
    /// user code failures:
    /// - `pool`: Infrastructure error (shutdown, timeout, exhausted, etc.)
    /// - `body`: User body threw an error
    ///
    /// ## Pattern Matching
    ///
    /// ```swift
    /// do {
    ///     try await pool { conn in try conn.query() }
    /// } catch {
    ///     switch error {
    ///     case .pool(.exhausted): // retry later
    ///     case .pool(.timeout): // operation took too long
    ///     case .pool(.shutdown): // pool is closing
    ///     case .pool(.cancelled): // task was cancelled
    ///     case .body(let e): // user code failed
    ///     }
    /// }
    /// ```
    ///
    /// ## Workaround Note
    ///
    /// This type is intentionally hoisted to `IO._PoolFailure` (not nested in
    /// `IO.Pool<Resource>`) due to Swift compiler bug #86347. The public API
    /// remains `IO.Pool<Resource>.Failure` via typealias.
    public enum _PoolFailure<Body: Swift.Error & Sendable>: Swift.Error, Sendable {
        /// Pool infrastructure error.
        ///
        /// The pool could not service the request due to infrastructure issues:
        /// shutdown, timeout, exhaustion, cancellation, etc.
        case pool(IO._PoolError)

        /// User body code threw an error.
        case body(Body)
    }
}

// MARK: - Equatable

extension IO._PoolFailure: Equatable where Body: Equatable {}

// MARK: - CustomStringConvertible

extension IO._PoolFailure: CustomStringConvertible {
    public var description: String {
        switch self {
        case .pool(let error):
            "pool(\(error))"
        case .body(let error):
            "body(\(error))"
        }
    }
}
