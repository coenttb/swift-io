//
//  IO.Blocking.Ticket.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 24/12/2025.
//

extension IO.Blocking {
    /// A unique identifier for an accepted job.
    ///
    /// Tickets are assigned at acceptance time and used to correlate
    /// job completion with waiting callers. Each ticket is unique
    /// within a Threads instance.
    public struct Ticket: Hashable, Sendable {
        public let rawValue: UInt64

        public init(rawValue: UInt64) {
            self.rawValue = rawValue
        }
    }
}
