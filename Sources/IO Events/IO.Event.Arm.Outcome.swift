//
//  IO.Event.Arm.Outcome.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 28/12/2025.
//

extension IO.Event.Arm {
    /// Simplified outcome for batch operations.
    ///
    /// Unlike `Arm.Registering.Outcome`, this is `Copyable` because it doesn't
    /// return tokens. Use when you don't need tokens back (e.g., testing timeouts).
    @frozen
    public enum Outcome: Sendable {
        /// Arming succeeded - includes the event that triggered it.
        case armed(IO.Event)
        /// Arming failed - includes the failure reason.
        case failed(IO.Event.Failure)
    }
}
