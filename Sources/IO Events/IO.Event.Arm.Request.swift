//
//  IO.Event.Arm.Request.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 28/12/2025.
//

extension IO.Event.Arm {
    /// A request to arm a registration with optional deadline.
    ///
    /// Used with `armTwo` and similar batch methods.
    /// This enables concurrent deadline testing and efficient multi-connection setup.
    @frozen
    public struct Request: ~Copyable, Sendable {
        /// The token to arm (consumed).
        public var token: IO.Event.Token<IO.Event.Registering>

        /// The interest to wait for.
        public let interest: IO.Event.Interest

        /// Optional deadline for this arm operation.
        public let deadline: IO.Event.Deadline?

        /// Creates an arm request.
        public init(
            token: consuming IO.Event.Token<IO.Event.Registering>,
            interest: IO.Event.Interest,
            deadline: IO.Event.Deadline? = nil
        ) {
            self.token = token
            self.interest = interest
            self.deadline = deadline
        }
    }
}
