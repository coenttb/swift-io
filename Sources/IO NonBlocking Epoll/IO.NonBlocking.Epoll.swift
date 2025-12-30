//
//  IO.NonBlocking.Epoll.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 29/12/2025.
//

#if canImport(Glibc)

@_exported public import IO_NonBlocking_Driver

extension IO.NonBlocking {
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
    /// let driver = IO.NonBlocking.Epoll.driver()
    /// let selector = try IO.NonBlocking.Selector.make(driver: driver)
    /// ```
    public enum Epoll {}
}

extension IO.NonBlocking.Epoll {
    /// Creates an epoll-based driver.
    ///
    /// - Returns: A driver configured for epoll operations.
    public static func driver() -> IO.NonBlocking.Driver {
        IO.NonBlocking.Driver(
            capabilities: IO.NonBlocking.Driver.Capabilities(
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
