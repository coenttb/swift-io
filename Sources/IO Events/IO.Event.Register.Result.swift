//
//  IO.Event.Register.Result.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 28/12/2025.
//

extension IO.Event.Register {
    /// Result of registering a descriptor.
    ///
    /// Contains the registration ID and a token for arming.
    /// This struct is ~Copyable because it contains a move-only Token.
    @frozen
    public struct Result: ~Copyable, Sendable {
        /// The registration ID.
        public let id: IO.Event.ID

        /// Token for arming the registration.
        public var token: IO.Event.Token<IO.Event.Registering>

        @usableFromInline
        package init(id: IO.Event.ID, token: consuming IO.Event.Token<IO.Event.Registering>) {
            self.id = id
            self.token = token
        }
    }
}
