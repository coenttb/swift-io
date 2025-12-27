//
//  IO.Executor.Error.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 24/12/2025.
//

extension IO.Executor {
    /// Errors specific to the executor.
    ///
    /// - Note: Shutdown is not represented here. Lifecycle conditions
    ///   are expressed via `IO.Lifecycle.Error<...>` at API boundaries.
    public enum Error: Swift.Error, Sendable, Equatable {
        /// The ID's scope doesn't match this executor.
        case scopeMismatch

        /// The handle ID was not found in the registry.
        case handleNotFound

        /// The operation is not valid in the current state.
        case invalidState
    }
}
