//
//  IO.NonBlocking.Event.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 28/12/2025.
//

extension IO.NonBlocking {
    /// A readiness event from the kernel selector.
    ///
    /// Events are produced by the driver's poll operation and represent
    /// what readiness conditions are now true for a registered descriptor.
    ///
    /// ## Thread Safety
    /// Events are Sendable and can cross the poll thread → selector actor boundary.
    ///
    /// ## Usage
    /// ```swift
    /// let (token, event) = try await selector.arm(registrationToken)
    /// if event.interest.contains(.read) {
    ///     // Safe to read without blocking
    /// }
    /// if event.flags.contains(.hangup) {
    ///     // Peer closed connection
    /// }
    /// ```
    public struct Event: Sendable, Equatable {
        /// The registration ID this event belongs to.
        public let id: ID

        /// Which interests are now ready.
        ///
        /// May contain multiple bits if both read and write are ready.
        public let interest: Interest

        /// Additional status flags (error, hangup, etc.).
        public let flags: Flags

        /// Creates an event with the specified components.
        public init(id: ID, interest: Interest, flags: Flags = []) {
            self.id = id
            self.interest = interest
            self.flags = flags
        }

        /// An empty event for buffer initialization.
        public static let empty = Event(id: ID(raw: 0), interest: [], flags: [])
    }
}

// MARK: - CustomStringConvertible

extension IO.NonBlocking.Event: CustomStringConvertible {
    public var description: String {
        var parts = ["Event(id: \(id.raw), interest: \(interest)"]
        if !flags.isEmpty {
            parts.append(", flags: \(flags)")
        }
        return parts.joined() + ")"
    }
}
