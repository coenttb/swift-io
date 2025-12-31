//
//  IO.Event.ID.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 28/12/2025.
//

extension IO.Event {
    /// Stable registration identity for selector operations.
    ///
    /// IDs are assigned by the selector during registration and remain
    /// stable for the lifetime of the registration. They are used to:
    /// - Look up registrations in the selector's tables
    /// - Associate events with their source registrations
    /// - Key permit storage for non-lossy readiness tracking
    ///
    /// ## Properties
    /// - **Copyable**: Can be freely copied for lookups and storage
    /// - **Hashable**: Can be used as dictionary keys
    /// - **Sendable**: Safe to pass across isolation boundaries
    ///
    /// ## Relationship to Token
    /// - `ID` is the identity (copyable, for lookups)
    /// - `Token<Phase>` is the capability (move-only, for API safety)
    public struct ID: Hashable, Sendable {
        /// The raw identifier value.
        ///
        /// Typically derived from descriptor number or selector-assigned sequence.
        public let raw: UInt64

        /// Creates an ID with the given raw value.
        public init(raw: UInt64) {
            self.raw = raw
        }
    }
}

// MARK: - CustomStringConvertible

extension IO.Event.ID: CustomStringConvertible {
    public var description: String {
        "ID(\(raw))"
    }
}
