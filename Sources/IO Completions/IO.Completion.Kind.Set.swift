//
//  IO.Completion.Kind.Set.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 31/12/2025.
//

extension IO.Completion.Kind {
    /// A set of operation kinds, used for capability declarations.
    ///
    /// ## Usage
    ///
    /// ```swift
    /// let supported = driver.capabilities.supportedKinds
    /// if supported.contains(.accept) {
    ///     // Can use accept operations
    /// }
    /// ```
    public struct Set: OptionSet, Sendable, Hashable {
        public let rawValue: UInt16

        @inlinable
        public init(rawValue: UInt16) {
            self.rawValue = rawValue
        }

        /// Creates a set containing a single kind.
        @inlinable
        public init(_ kind: IO.Completion.Kind) {
            self.rawValue = 1 << UInt16(kind.rawValue)
        }

        /// Whether this set contains the given kind.
        @inlinable
        public func contains(_ kind: IO.Completion.Kind) -> Bool {
            contains(Set(kind))
        }

        // MARK: - Predefined Sets

        /// Operations supported by Windows IOCP.
        public static let iocp: Set = [
            Set(.nop),
            Set(.read),
            Set(.write),
            Set(.accept),
            Set(.connect),
            Set(.send),
            Set(.recv),
            Set(.cancel),
            Set(.wakeup),
        ]

        /// Operations supported by Linux io_uring.
        public static let iouring: Set = [
            Set(.nop),
            Set(.read),
            Set(.write),
            Set(.accept),
            Set(.connect),
            Set(.send),
            Set(.recv),
            Set(.fsync),
            Set(.close),
            Set(.cancel),
            Set(.wakeup),
        ]
    }
}
