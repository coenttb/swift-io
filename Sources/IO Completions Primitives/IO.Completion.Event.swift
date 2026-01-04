//
//  IO.Completion.Event.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 31/12/2025.
//

public import IO_Primitives
public import Kernel

extension IO.Completion {
    /// A completion event from the driver.
    ///
    /// Events are produced by the driver's poll operation and represent
    /// completed (or cancelled) operations.
    ///
    /// ## Thread Safety
    ///
    /// Events are `Sendable` and can cross the poll thread → queue actor boundary.
    ///
    /// ## Usage
    ///
    /// ```swift
    /// let events = try driver.poll(handle, deadline: nil, into: &buffer)
    /// for event in events {
    ///     switch event.outcome {
    ///     case .success(let success):
    ///         // Handle completion
    ///     case .failure(let error):
    ///         // Handle error
    ///     case .cancelled:
    ///         // Handle cancellation
    ///     }
    /// }
    /// ```
    public struct Event: Sendable, Equatable {
        /// The operation ID this event belongs to.
        public let id: ID

        /// The kind of operation that completed.
        public let kind: Kind

        /// The outcome of the operation.
        public let outcome: Outcome

        /// Additional completion flags.
        public let flags: Flags

        /// Platform-specific user data.
        ///
        /// Internal use only. Used for:
        /// - io_uring: Pointer recovery from user_data
        /// - IOCP: Container-of pointer arithmetic
        @usableFromInline
        package let userData: UInt64

        /// Creates a completion event.
        @inlinable
        public init(
            id: IO.Completion.ID,
            kind: IO.Completion.Kind,
            outcome: IO.Completion.Outcome,
            flags: IO.Completion.Flags = [],
            userData: UInt64 = 0
        ) {
            self.id = id
            self.kind = kind
            self.outcome = outcome
            self.flags = flags
            self.userData = userData
        }

        /// An empty event for buffer initialization.
        public static let empty = Event(
            id: .zero,
            kind: IO.Completion.Kind.nop,
            outcome: IO.Completion.Outcome.cancelled
        )
    }
}

// MARK: - CustomStringConvertible

extension IO.Completion.Event: CustomStringConvertible {
    public var description: String {
        var parts = ["Event(id: \(id._rawValue), kind: \(kind), outcome: \(outcome)"]
        if !flags.isEmpty {
            parts.append(", flags: \(flags)")
        }
        return parts.joined() + ")"
    }
}
