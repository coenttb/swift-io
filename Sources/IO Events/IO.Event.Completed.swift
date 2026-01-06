//
//  IO.Event.Completed.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 28/12/2025.
//

extension IO.Event {
    /// Phase indicating a completed operation.
    ///
    /// A token in this phase cannot be used for further operations.
    /// The registration has either:
    /// - Received a readiness event
    /// - Been cancelled
    /// - Been deregistered
    public enum Completed {}
}
