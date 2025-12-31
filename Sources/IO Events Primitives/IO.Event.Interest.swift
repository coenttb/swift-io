//
//  IO.Event.Interest.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 28/12/2025.
//

extension IO.Event {
    /// Requested readiness interests for non-blocking I/O operations.
    ///
    /// Interests represent what readiness conditions the caller wants to be
    /// notified about. Multiple interests can be combined using set operations.
    ///
    /// ## Usage
    /// ```swift
    /// let interest: Interest = [.read, .write]
    /// let (id, token) = try await selector.register(fd, interest: interest)
    /// ```
    ///
    /// ## Platform Mapping
    /// - **kqueue**: `EVFILT_READ`, `EVFILT_WRITE`
    /// - **epoll**: `EPOLLIN`, `EPOLLOUT`, `EPOLLPRI`
    /// - **IOCP**: Mapped to overlapped operation types
    public struct Interest: OptionSet, Sendable, Hashable {
        public let rawValue: UInt8

        public init(rawValue: UInt8) {
            self.rawValue = rawValue
        }

        /// Interest in read readiness (data available to read).
        public static let read = Interest(rawValue: 1 << 0)

        /// Interest in write readiness (buffer space available for writing).
        public static let write = Interest(rawValue: 1 << 1)

        /// Interest in priority/out-of-band data (platform-specific).
        ///
        /// On Linux, this maps to `EPOLLPRI` (urgent data).
        /// On Darwin, this is less commonly used.
        /// On Windows, this may not be directly supported.
        public static let priority = Interest(rawValue: 1 << 2)
    }
}

// MARK: - CustomStringConvertible

extension IO.Event.Interest: CustomStringConvertible {
    public var description: String {
        var parts: [String] = []
        if contains(.read) { parts.append("read") }
        if contains(.write) { parts.append("write") }
        if contains(.priority) { parts.append("priority") }
        return parts.isEmpty ? "none" : parts.joined(separator: "|")
    }
}
