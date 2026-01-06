//
//  IO.Event.Registration.Payload.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 29/12/2025.
//

extension IO.Event.Registration {
    /// Payload of a successful registration reply.
    public enum Payload: Sendable, Equatable {
        /// Registration succeeded, returning the assigned ID.
        case registered(IO.Event.ID)

        /// Modification succeeded.
        case modified

        /// Deregistration succeeded.
        case deregistered
    }
}
