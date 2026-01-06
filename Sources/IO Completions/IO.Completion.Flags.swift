//
//  IO.Completion.Flags.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 31/12/2025.
//

public import IO_Primitives

extension IO.Completion {
    /// Additional flags on a completion event.
    ///
    /// Flags provide supplementary information about the completion:
    /// - `more`: More completions are available (batching hint)
    /// - `bufferSelect`: Buffer was selected from a registered buffer pool
    ///
    /// ## Platform Mapping
    ///
    /// - **io_uring**: Maps from `IORING_CQE_F_*` flags
    /// - **IOCP**: Limited flag support, mainly for batching hints
    public struct Flags: OptionSet, Sendable, Hashable {
        public let rawValue: UInt8

        @inlinable
        public init(rawValue: UInt8) {
            self.rawValue = rawValue
        }

        /// More completions are immediately available.
        ///
        /// Hint to continue draining without re-polling.
        /// Maps to `IORING_CQE_F_MORE` on io_uring.
        public static let more = Flags(rawValue: 1 << 0)

        /// Buffer was selected from a registered buffer pool.
        ///
        /// Maps to `IORING_CQE_F_BUFFER` on io_uring.
        /// The buffer ID is encoded in the result.
        public static let bufferSelect = Flags(rawValue: 1 << 1)

        /// The operation completed with a short count.
        ///
        /// For read/write operations, indicates fewer bytes
        /// were transferred than requested.
        public static let shortCount = Flags(rawValue: 1 << 2)
    }
}

// MARK: - CustomStringConvertible

extension IO.Completion.Flags: CustomStringConvertible {
    public var description: String {
        var parts: [String] = []
        if contains(.more) { parts.append("more") }
        if contains(.bufferSelect) { parts.append("bufferSelect") }
        if contains(.shortCount) { parts.append("shortCount") }
        return "[\(parts.joined(separator: ", "))]"
    }
}
