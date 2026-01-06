//
//  IO.Event.Arm.Result.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 28/12/2025.
//

extension IO.Event.Arm {
    /// Result of arming a registration.
    ///
    /// Contains an armed token and the event that triggered it.
    /// This struct is ~Copyable because it contains a move-only Token.
    @frozen
    public struct Result: ~Copyable, Sendable {
        /// Token for modifying, deregistering, or cancelling.
        public var token: IO.Event.Token<IO.Event.Armed>

        /// The event that triggered readiness.
        public let event: IO.Event

        @usableFromInline
        package init(token: consuming IO.Event.Token<IO.Event.Armed>, event: IO.Event) {
            self.token = token
            self.event = event
        }
    }
}
