//
//  IO.Completion.Success.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 31/12/2025.
//

public import Kernel

extension IO.Completion {
    /// Success variants for different operation kinds.
    ///
    /// The success type depends on the operation kind:
    /// - `bytes(Int)`: For read/write/send/recv operations
    /// - `accepted(Kernel.Descriptor)`: For accept operations
    /// - `connected`: For connect operations
    /// - `completed`: For nop/fsync/close operations
    public enum Success: Sendable, Equatable {
        /// Number of bytes transferred.
        ///
        /// Used for: read, write, send, recv
        case bytes(Int)

        /// Accepted connection descriptor.
        ///
        /// Used for: accept
        case accepted(descriptor: Kernel.Descriptor)

        /// Connection established.
        ///
        /// Used for: connect
        case connected

        /// Generic completion (no payload).
        ///
        /// Used for: nop, fsync, close, cancel, wakeup
        case completed
    }
}

// MARK: - CustomStringConvertible

extension IO.Completion.Success: CustomStringConvertible {
    public var description: String {
        switch self {
        case .bytes(let count):
            "bytes(\(count))"
        case .accepted(let descriptor):
            "accepted(\(descriptor))"
        case .connected:
            "connected"
        case .completed:
            "completed"
        }
    }
}
