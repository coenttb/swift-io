//
//  IO.Pool.Error.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 07/01/2026.
//

extension IO.Pool where Resource: ~Copyable {
    /// Infrastructure errors from pool operations.
    ///
    /// ## Design
    ///
    /// This type captures pool-level failures that prevent operations from
    /// completing. These are distinct from user body errors which flow
    /// through `IO.Pool.Scoped.Failure`.
    ///
    /// ## Error Categories
    ///
    /// - Lifecycle: `shutdown` - pool is no longer accepting operations
    /// - Capacity: `exhausted`, `timeout` - no resources available
    /// - Validation: `scopeMismatch`, `invalidID` - ID errors
    /// - Cancellation: `cancelled` - task was cancelled
    ///
    /// ## Implementation Note
    ///
    /// This is a typealias to `IO._PoolError` to work around Swift compiler
    /// bug #86347. When the bug is fixed, the definition can be moved here.
    public typealias Error = IO._PoolError
}
