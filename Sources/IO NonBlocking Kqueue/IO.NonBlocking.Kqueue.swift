//
//  IO.NonBlocking.Kqueue.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 28/12/2025.
//

#if canImport(Darwin)

@_exported public import IO_NonBlocking_Driver

extension IO.NonBlocking {
    /// Kqueue-based non-blocking I/O backend for Darwin platforms.
    ///
    /// Kqueue is the native event notification system for macOS, iOS, and other
    /// Darwin-based operating systems. It provides efficient, scalable monitoring
    /// of file descriptors and other kernel events.
    ///
    /// ## Capabilities
    /// - Edge-triggered via `EV_CLEAR`
    /// - Supports read, write, and exceptional conditions
    /// - Wakeup via `EVFILT_USER`
    ///
    /// ## Usage
    /// ```swift
    /// let driver = IO.NonBlocking.Kqueue.driver()
    /// let selector = try IO.NonBlocking.Selector.make(driver: driver)
    /// ```
    public enum Kqueue {}
}

extension IO.NonBlocking.Kqueue {
    /// Creates a kqueue-based driver.
    ///
    /// - Returns: A driver configured for kqueue operations.
    public static func driver() -> IO.NonBlocking.Driver {
        IO.NonBlocking.Driver(
            capabilities: IO.NonBlocking.Driver.Capabilities(
                maxEvents: 256,
                supportsEdgeTriggered: true,
                isCompletionBased: false
            ),
            create: KqueueOperations.create,
            register: KqueueOperations.register,
            modify: KqueueOperations.modify,
            deregister: KqueueOperations.deregister,
            poll: KqueueOperations.poll,
            close: KqueueOperations.close,
            createWakeupChannel: KqueueOperations.createWakeupChannel
        )
    }
}

#endif
