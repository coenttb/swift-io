//
//  IO.Blocking.Error.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 28/12/2025.
//

extension IO.Blocking {
    /// Errors from the IO.Blocking subsystem.
    ///
    /// This type wraps errors from Blocking components (currently only Lane).
    /// Lifecycle concerns (shutdown/cancellation) are NOT in this type -
    /// they are surfaced through `IO.Lifecycle.Error` at the Pool boundary.
    public enum Error: Swift.Error, Sendable, Equatable {
        /// Lane infrastructure error.
        case lane(Lane.Error)
    }
}

// MARK: - CustomStringConvertible

extension IO.Blocking.Error: CustomStringConvertible {
    public var description: String {
        switch self {
        case .lane(let error):
            return "Lane error: \(error)"
        }
    }
}
