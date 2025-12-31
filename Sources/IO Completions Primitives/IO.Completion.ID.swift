//
//  IO.Completion.ID.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 31/12/2025.
//

public import IO_Primitives

extension IO.Completion {
    /// Unique identifier for a submitted completion operation.
    ///
    /// IDs are assigned by the completion queue when an operation is submitted.
    /// They are used for:
    /// - Correlating completions to their originating operations
    /// - Cancellation (as a secondary key, primary is the operation handle)
    /// - Logging and debugging
    ///
    /// ## Thread Safety
    ///
    /// `ID` is `Hashable` and `Sendable`, safe to pass across isolation boundaries.
    ///
    /// ## Platform Mapping
    ///
    /// - **IOCP**: Stored in completion key
    /// - **io_uring**: Stored in user_data field
    /// - **EventsAdapter**: Internal map key
    public struct ID: Hashable, Sendable {
        /// The raw 64-bit identifier value.
        public let raw: UInt64

        /// Creates an ID from a raw value.
        @inlinable
        public init(raw: UInt64) {
            self.raw = raw
        }
    }
}

// MARK: - CustomStringConvertible

extension IO.Completion.ID: CustomStringConvertible {
    public var description: String {
        "Completion.ID(\(raw))"
    }
}

// MARK: - ExpressibleByIntegerLiteral

extension IO.Completion.ID: ExpressibleByIntegerLiteral {
    @inlinable
    public init(integerLiteral value: UInt64) {
        self.raw = value
    }
}
