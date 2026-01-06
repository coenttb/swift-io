//
//  IO.Completion.Error.Lifecycle.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 31/12/2025.
//

extension IO.Completion.Error {
    /// Lifecycle errors.
    public enum Lifecycle: Swift.Error, Sendable, Equatable {
        /// The queue is shutting down.
        case shutdownInProgress

        /// The queue has been closed.
        case queueClosed
    }
}

// MARK: - CustomStringConvertible

extension IO.Completion.Error.Lifecycle: CustomStringConvertible {
    public var description: String {
        switch self {
        case .shutdownInProgress: "shutdownInProgress"
        case .queueClosed: "queueClosed"
        }
    }
}
