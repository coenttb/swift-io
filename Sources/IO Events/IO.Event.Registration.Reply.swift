//
//  IO.Event.Registration.Reply.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 29/12/2025.
//

extension IO.Event.Registration {
    /// A reply from the poll thread to the selector for a registration request.
    ///
    /// Replies are pushed by the poll thread via `Reply.Bridge` and processed
    /// by the selector actor. This ensures all continuations are resumed on
    /// the selector executor (single resumption funnel).
    public struct Reply: Sendable {
        /// The reply ID matching the original request.
        public let id: ID

        /// The result of the registration operation.
        public let result: Result<Payload, IO.Event.Error>

        public init(id: ID, result: Result<Payload, IO.Event.Error>) {
            self.id = id
            self.result = result
        }
    }
}
