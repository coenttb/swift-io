//
//  IO.Event.Arm.Handle.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 28/12/2025.
//

extension IO.Event.Arm {
    /// Handle for a pending arm operation.
    ///
    /// Returned by `beginArmDiscardingToken` and consumed by `awaitArm`.
    /// This is `Copyable` (unlike tokens) so it can be captured in `async let`.
    ///
    /// The handle includes a generation number to detect stale completions.
    /// If the underlying waiter is removed (event, deregister, shutdown) before
    /// `awaitArm` is called, the generation mismatch causes immediate failure.
    @frozen
    public struct Handle: Sendable, Hashable {
        /// The registration ID.
        public let id: IO.Event.ID

        /// The interest this handle is waiting for.
        public let interest: IO.Event.Interest

        /// Generation at the time of handle creation.
        ///
        /// Used to detect if the waiter was already consumed by an event
        /// or invalidated by deregistration before `awaitArm` was called.
        public let generation: UInt64
    }
}

extension IO.Event.Arm.Handle {
    /// Internal key for permit/waiter lookup.
    var key: IO.Event.Selector.Permit.Key {
        IO.Event.Selector.Permit.Key(id: id, interest: interest)
    }
}
