//
//  IO.Completion.Operation.Kind.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 31/12/2025.
//

public import IO_Primitives

extension IO.Completion {
    /// The kind of completion operation.
    ///
    /// Each kind maps to platform-specific submission mechanisms:
    /// - **IOCP**: WSARecv, WSASend, ReadFile, WriteFile, AcceptEx, ConnectEx
    /// - **io_uring**: IORING_OP_* constants
    ///
    /// ## Capability Checking
    ///
    /// Not all backends support all kinds. Use `Driver.capabilities.supportedKinds`
    /// to check availability before submission.
    public enum Kind: UInt8, Sendable, Hashable, CaseIterable {
        /// No-operation, used for wakeup and testing.
        case nop = 0

        /// Read from a file descriptor into a buffer.
        case read = 1

        /// Write from a buffer to a file descriptor.
        case write = 2

        /// Accept a new connection on a listening socket.
        case accept = 3

        /// Connect to a remote address.
        case connect = 4

        /// Send data on a connected socket.
        case send = 5

        /// Receive data from a connected socket.
        case recv = 6

        /// Flush file data to storage.
        case fsync = 7

        /// Close a file descriptor.
        case close = 8

        /// Cancel a pending operation.
        case cancel = 9

        /// Internal wakeup signal.
        case wakeup = 10
    }
}

// MARK: - CustomStringConvertible

extension IO.Completion.Kind: CustomStringConvertible {
    public var description: String {
        switch self {
        case .nop: "nop"
        case .read: "read"
        case .write: "write"
        case .accept: "accept"
        case .connect: "connect"
        case .send: "send"
        case .recv: "recv"
        case .fsync: "fsync"
        case .close: "close"
        case .cancel: "cancel"
        case .wakeup: "wakeup"
        }
    }
}

// MARK: - KindSet

extension IO.Completion {
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
    public struct KindSet: OptionSet, Sendable, Hashable {
        public let rawValue: UInt16

        @inlinable
        public init(rawValue: UInt16) {
            self.rawValue = rawValue
        }

        /// Creates a set containing a single kind.
        @inlinable
        public init(_ kind: Kind) {
            self.rawValue = 1 << UInt16(kind.rawValue)
        }

        /// Whether this set contains the given kind.
        @inlinable
        public func contains(_ kind: Kind) -> Bool {
            contains(KindSet(kind))
        }

        // MARK: - Predefined Sets

        /// Operations supported by Windows IOCP.
        public static let iocp: KindSet = [
            KindSet(.nop),
            KindSet(.read),
            KindSet(.write),
            KindSet(.accept),
            KindSet(.connect),
            KindSet(.send),
            KindSet(.recv),
            KindSet(.cancel),
            KindSet(.wakeup),
        ]

        /// Operations supported by Linux io_uring.
        public static let iouring: KindSet = [
            KindSet(.nop),
            KindSet(.read),
            KindSet(.write),
            KindSet(.accept),
            KindSet(.connect),
            KindSet(.send),
            KindSet(.recv),
            KindSet(.fsync),
            KindSet(.close),
            KindSet(.cancel),
            KindSet(.wakeup),
        ]
    }
}
