//
//  IO.Blocking.Threads.Ticket.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 24/12/2025.
//

extension IO.Blocking.Threads {
    /// A unique identifier for an accepted job.
    ///
    /// Tickets are assigned at acceptance time and used to correlate
    /// job completion with waiting callers. Each ticket is unique
    /// within a Threads instance.
    struct Ticket: Hashable, Sendable {
        let rawValue: UInt64

        init(rawValue: UInt64) {
            self.rawValue = rawValue
        }
    }
}
