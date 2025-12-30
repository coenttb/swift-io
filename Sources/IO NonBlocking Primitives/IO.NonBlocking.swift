//
//  IO.NonBlocking.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 28/12/2025.
//

@_exported public import IO_Primitives

extension IO {
    /// Namespace for non-blocking I/O primitives.
    ///
    /// Provides infrastructure for event-driven, non-blocking I/O using
    /// platform-specific selectors (kqueue on Darwin, epoll on Linux, IOCP on Windows).
    ///
    /// ## Architecture
    ///
    /// The non-blocking I/O system is layered:
    /// 1. **Primitives** (this module): Invariant types, leaf errors, IDs, tokens
    /// 2. **Driver**: Protocol witness struct for platform backends
    /// 3. **Backends**: Platform-specific implementations (kqueue, epoll, IOCP)
    /// 4. **Runtime**: Selector actor, channels, sockets
    ///
    /// ## Thread Safety Model
    ///
    /// - Poll thread owns the driver handle for all blocking operations
    /// - Selector actor owns state (waiters, permits, registrations)
    /// - Communication via thread-safe primitives: EventBridge, WakeupChannel
    /// - No continuations resumed from poll thread
    public enum NonBlocking {}
}
