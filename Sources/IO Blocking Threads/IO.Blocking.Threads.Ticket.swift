//
//  IO.Blocking.Threads.Ticket.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 24/12/2025.
//

extension IO.Blocking.Threads {
    /// Tag type for job tickets.
    public enum TicketTag {}

    /// A unique identifier for an accepted job.
    ///
    /// Tickets are assigned at acceptance time and used to correlate
    /// job completion with waiting callers. Each ticket is unique
    /// within a Threads instance.
    ///
    /// This is a typealias to `Kernel.ID<TicketTag>`, providing type-safe
    /// identification using the kernel-level generic ID implementation.
    public typealias Ticket = Kernel.ID<TicketTag>
}
