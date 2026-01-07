//
//  IO.Pool.Failure.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 07/01/2026.
//

extension IO.Pool where Resource: ~Copyable {
    /// Composed error for pool scoped operations.
    ///
    /// ## Design
    ///
    /// This two-case error cleanly separates pool infrastructure failures from
    /// user code failures:
    /// - `pool`: Infrastructure error (shutdown, timeout, exhausted, etc.)
    /// - `body`: User body threw an error
    ///
    /// ## Usage
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
    /// ## Implementation Note
    ///
    /// This is a typealias to `IO._PoolFailure` to work around Swift compiler
    /// bug #86347. When the bug is fixed, the definition can be moved here.
    public typealias Failure<Body: Swift.Error & Sendable> = IO._PoolFailure<Body>
}
