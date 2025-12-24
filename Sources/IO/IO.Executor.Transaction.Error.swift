//
//  IO.Executor.Transaction.Error.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 24/12/2025.
//

extension IO.Executor.Transaction {
    /// Typed error for transaction operations.
    /// Generic over the body error E - no existentials, full structure preserved.
    public enum Error<E: Swift.Error & Sendable>: Swift.Error, Sendable {
        case lane(IO.Blocking.Failure)
        case handle(IO.Handle.Error)
        case body(E)
    }
}
