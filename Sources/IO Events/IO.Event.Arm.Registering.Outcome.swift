//
//  IO.Event.Arm.Registering.Outcome.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 28/12/2025.
//

extension IO.Event.Arm.Registering {
    /// Outcome of arming from a `Token<Registering>`.
    ///
    /// Uses an outcome enum instead of throwing because Swift's `Error` protocol
    /// requires `Copyable`, which is incompatible with move-only tokens.
    /// This enum makes token loss unrepresentable at the API boundary.
    public enum Outcome: ~Copyable, Sendable {
        /// Arming succeeded - returns the armed result with token and event.
        case armed(IO.Event.Arm.Result)
        /// Arming failed - returns the original token for restoration.
        case failed(token: IO.Event.Token<IO.Event.Registering>, failure: IO.Event.Failure)
    }
}
