//
//  IO.Completion.Outcome.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 31/12/2025.
//

public import IO_Primitives
public import Kernel

extension IO.Completion {
    /// The outcome of a completed operation.
    ///
    /// Represents the three possible outcomes:
    /// - `success`: Operation completed successfully
    /// - `failure`: Operation failed with a kernel error
    /// - `cancelled`: Operation was cancelled before completion
    ///
    /// ## Naming
    ///
    /// Named `Outcome` (not `Result`) to avoid collision with `Swift.Result`.
    /// This type represents the kernel-level completion status, distinct from
    /// `IO.Completion.Submit.Result` which carries the buffer back to the caller.
    ///
    /// ## Thread Safety
    ///
    /// `Outcome` is `Sendable` and can cross isolation boundaries.
    public enum Outcome: Sendable, Equatable {
        /// Operation completed successfully.
        case success(Success)

        /// Operation failed with a kernel error.
        case failure(Kernel.Error)

        /// Operation was cancelled.
        case cancellation
    }

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

extension IO.Completion.Outcome: CustomStringConvertible {
    public var description: String {
        switch self {
        case .success(let success):
            "success(\(success))"
        case .failure(let error):
            "failure(\(error))"
        case .cancellation:
            "cancelled"
        }
    }
}

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
