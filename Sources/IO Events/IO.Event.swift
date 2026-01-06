//
//  IO.Event.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 28/12/2025.
//

@_exported public import IO_Primitives
@_exported public import Kernel

extension IO {
    /// A readiness event from the kernel selector.
    ///
    /// This is a typealias to `Kernel.Event`, which provides the core event
    /// representation. IO-specific extensions (like `Token<Phase>`) are added
    /// via extensions on this typealias.
    ///
    /// ## Architecture
    ///
    /// The event-driven I/O system is layered:
    /// 1. **Kernel**: `Event`, `Interest`, `Flags`, `ID` (platform-agnostic primitives)
    /// 2. **IO**: `Token`, `Driver`, `Selector` (async coordination)
    /// 3. **Backends**: Platform-specific implementations (kqueue, epoll, IOCP)
    ///
    /// ## Thread Safety
    ///
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
    public typealias Event = Kernel.Event
}
