//
//  IO.Completion.Error.Capability.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 31/12/2025.
//

extension IO.Completion.Error {
    /// Capability errors.
    public enum Capability: Swift.Error, Sendable, Equatable {
        /// The operation kind is not supported by this backend.
        case unsupportedKind(IO.Completion.Kind)

        /// No suitable backend is available.
        case backendUnavailable
    }
}

// MARK: - CustomStringConvertible

extension IO.Completion.Error.Capability: CustomStringConvertible {
    public var description: String {
        switch self {
        case .unsupportedKind(let kind): "unsupportedKind(\(kind))"
        case .backendUnavailable: "backendUnavailable"
        }
    }
}
