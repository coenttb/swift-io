//
//  IO.Executor.Transaction.Error.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 24/12/2025.
//

extension IO.Executor.Transaction {
    /// Typed error for transaction operations.
    ///
    /// Generic over the body error E - no existentials, full structure preserved.
    ///
    public enum Error<E: Swift.Error & Sendable>: Swift.Error, Sendable {

        // ## Design
        // - Lifecycle concerns (shutdown, cancellation) are NOT in this type.
        // - They are surfaced through `IO.Lifecycle.Error` at the Pool boundary.
        // - Uses `IO.Blocking.Error` (not `Failure`) to exclude lifecycle cases.
        /// Lane infrastructure errors (excludes lifecycle concerns).
        case lane(IO.Blocking.Error)

        /// Handle-related errors.
        case handle(IO.Handle.Error)

        /// Body-specific error.
        case body(E)
    }
}
