//
//  IO.File.Access.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 30/12/2025.
//

extension IO.File {
    /// Access mode flags for file operations.
    ///
    /// Access is modeled as an `OptionSet` to match kernel semantics:
    /// - POSIX: `O_RDONLY`, `O_WRONLY`, `O_RDWR`
    /// - Windows: `GENERIC_READ`, `GENERIC_WRITE`
    ///
    /// ## Usage
    ///
    /// ```swift
    /// // Read-only
    /// let handle = try IO.File.open(path, options: .init(access: .read))
    ///
    /// // Read-write
    /// let handle = try IO.File.open(path, options: .init(access: [.read, .write]))
    ///
    /// // Using convenience constant
    /// let handle = try IO.File.open(path, options: .init(access: .readWrite))
    /// ```
    public struct Access: OptionSet, Sendable, Equatable, Hashable {
        public let rawValue: UInt8

        public init(rawValue: UInt8) {
            self.rawValue = rawValue
        }

        /// Read access.
        public static let read = Access(rawValue: 1 << 0)

        /// Write access.
        public static let write = Access(rawValue: 1 << 1)

        /// Read and write access (convenience).
        public static let readWrite: Access = [.read, .write]
    }
}
