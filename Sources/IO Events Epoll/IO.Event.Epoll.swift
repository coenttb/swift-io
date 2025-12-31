//
//  IO.Event.Epoll.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 29/12/2025.
//

#if canImport(Glibc)

@_exported public import IO_Events_Driver

extension IO.Event {
    /// Epoll-based non-blocking I/O backend for Linux.
    ///
    /// Epoll is the native event notification system for Linux. It provides
    /// efficient, scalable monitoring of file descriptors.
    ///
    /// ## Capabilities
    /// - Edge-triggered via `EPOLLET`
    /// - Supports read, write, and exceptional conditions
    /// - Wakeup via `eventfd`
    ///
    /// ## Usage
    /// ```swift
    /// let driver = IO.Event.Epoll.driver()
    /// let selector = try IO.Event.Selector.make(driver: driver)
    /// ```
    public enum Epoll {}
}

extension IO.Event.Epoll {
    /// Creates an epoll-based driver.
    ///
    /// - Returns: A driver configured for epoll operations.
    public static func driver() -> IO.Event.Driver {
        IO.Event.Driver(
            capabilities: IO.Event.Driver.Capabilities(
                maxEvents: 256,
                supportsEdgeTriggered: true,
                isCompletionBased: false
            ),
            create: EpollOperations.create,
            register: EpollOperations.register,
            modify: EpollOperations.modify,
            deregister: EpollOperations.deregister,
            arm: EpollOperations.arm,
            poll: EpollOperations.poll,
            close: EpollOperations.close,
            createWakeupChannel: EpollOperations.createWakeupChannel
        )
    }
}

#endif
