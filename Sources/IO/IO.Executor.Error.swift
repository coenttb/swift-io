//
//  IO.Executor.Error.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 24/12/2025.
//

extension IO.Executor {
    /// Operational errors specific to the executor.
    ///
    /// This type contains only operational errors. Lifecycle concerns
    /// (shutdown) are surfaced through `IO.Lifecycle.Error` at the Pool boundary.
    ///
    /// ## Invariant
    /// `.invalidState` MUST NOT be used to encode shutdown. Shutdown is always
    /// surfaced as `IO.Lifecycle.Error.shutdownInProgress`.
    internal enum Error: Swift.Error, Sendable, Equatable {
        /// The ID's scope doesn't match this executor.
        case scopeMismatch

        /// The handle ID was not found in the registry.
        case handleNotFound

        /// The operation is not valid in the current state.
        /// Note: This MUST NOT encode shutdown - shutdown is a lifecycle concern.
        case invalidState
    }
}
