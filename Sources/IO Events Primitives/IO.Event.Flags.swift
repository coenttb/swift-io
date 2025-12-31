//
//  IO.Event.Flags.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 28/12/2025.
//

extension IO.Event {
    /// Additional status flags accompanying an event.
    ///
    /// Flags provide supplementary information about the event, such as
    /// whether an error occurred or whether the peer closed the connection.
    ///
    /// ## Platform Mapping
    /// - **kqueue**: `EV_EOF`, `EV_ERROR`
    /// - **epoll**: `EPOLLERR`, `EPOLLHUP`, `EPOLLRDHUP`
    /// - **IOCP**: Derived from completion status and WSA errors
    public struct Flags: OptionSet, Sendable, Hashable {
        public let rawValue: UInt8

        public init(rawValue: UInt8) {
            self.rawValue = rawValue
        }

        /// An error occurred on the descriptor.
        ///
        /// The next I/O operation will likely fail. The caller should
        /// check for the specific error via the appropriate syscall.
        public static let error = Flags(rawValue: 1 << 0)

        /// The connection has been closed or reset.
        ///
        /// Generic hangup indicating the connection is no longer usable
        /// in at least one direction.
        public static let hangup = Flags(rawValue: 1 << 1)

        /// The peer closed the read side (sent FIN).
        ///
        /// Reading will return EOF. The write side may still be open.
        /// This enables half-close detection for TLS close_notify.
        public static let readHangup = Flags(rawValue: 1 << 2)

        /// The peer closed the write side.
        ///
        /// Writing will fail. The read side may still have buffered data.
        public static let writeHangup = Flags(rawValue: 1 << 3)
    }
}

// MARK: - CustomStringConvertible

extension IO.Event.Flags: CustomStringConvertible {
    public var description: String {
        var parts: [String] = []
        if contains(.error) { parts.append("error") }
        if contains(.hangup) { parts.append("hangup") }
        if contains(.readHangup) { parts.append("readHangup") }
        if contains(.writeHangup) { parts.append("writeHangup") }
        return parts.isEmpty ? "none" : parts.joined(separator: "|")
    }
}
