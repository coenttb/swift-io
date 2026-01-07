//
//  IO.Pool.Error.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 07/01/2026.
//

extension IO.Pool where Resource: ~Copyable {
    /// Infrastructure errors from pool operations.
    ///
    /// ## Error Categories
    ///
    /// - Lifecycle: `shutdown` - pool is no longer accepting operations
    /// - Capacity: `exhausted`, `timeout` - no resources available
    /// - Validation: `scopeMismatch`, `invalidID` - ID errors
    /// - Cancellation: `cancelled` - task was cancelled
    ///
    /// ## Usage
    ///
    /// Pool errors appear in the `.pool` case of `IO.Pool.Failure<Body>`:
    ///
    /// ```swift
    /// do {
    ///     try await pool { conn in try conn.query() }
    /// } catch {
    ///     switch error {
    ///     case .pool(.shutdown): // pool is closing
    ///     case .pool(.exhausted): // retry later
    ///     case .body(let e): // user code failed
    ///     }
    /// }
    /// ```
    ///
    /// ## Implementation Note
    ///
    /// This is a typealias to `IO._PoolError` to work around Swift compiler
    /// bug #86347. When the bug is fixed, the definition can be moved here.
    public typealias Error = IO._PoolError
}
