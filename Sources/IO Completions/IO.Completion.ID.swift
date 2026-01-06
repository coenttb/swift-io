//
//  IO.Completion.ID.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 31/12/2025.
//

public import IO_Primitives
public import Kernel

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
    public typealias ID = Tagged<IO.Completion, UInt64>
}

// MARK: - Convenience Initializers

extension Tagged where Tag == IO.Completion, RawValue == UInt64 {
    /// The zero ID (often used as sentinel).
    public static let zero = Self(0)
}
