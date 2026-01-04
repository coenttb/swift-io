//
//  IO.File.Open.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 30/12/2025.
//

public import Kernel

// MARK: - Namespace

extension IO.File {
    /// Namespace for file opening types.
    public enum Open {}
}

// MARK: - Options

extension IO.File.Open {
    /// Options for opening a file.
    ///
    /// This is an IO-level convenience that bundles common open parameters.
    /// Uses kernel types directly where possible.
    public struct Options: Sendable, Equatable {
        /// Access mode (read, write, or both).
        ///
        /// Uses `Kernel.File.Open.Mode` directly from swift-kernel.
        public var mode: Kernel.File.Open.Mode

        /// Create the file if it doesn't exist.
        public var create: Bool

        /// Truncate the file to zero length on open.
        public var truncate: Bool

        /// Cache mode (buffered, direct, uncached, or auto).
        public var cache: Kernel.File.Direct.Mode

        /// Creates default options (read-only, buffered).
        public init() {
            self.mode = .read
            self.create = false
            self.truncate = false
            self.cache = .buffered
        }

        /// Creates options with specific access mode.
        public init(mode: Kernel.File.Open.Mode) {
            self.mode = mode
            self.create = false
            self.truncate = false
            self.cache = .buffered
        }
    }
}
