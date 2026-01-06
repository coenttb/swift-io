//
//  IO.Event.Driver+Platform.swift
//  swift-io
//
//  Platform-specific driver selection.
//

extension IO.Event.Driver {
    /// The platform-appropriate driver for the current operating system.
    ///
    /// Selects the best available event notification mechanism:
    /// - **Darwin (macOS/iOS)**: kqueue
    /// - **Linux**: epoll
    /// - **Windows**: IOCP (when implemented)
    ///
    /// ## Usage
    /// ```swift
    /// let selector = try await IO.Event.Selector.make(driver: .platform)
    /// ```
    public static var platform: IO.Event.Driver {
        #if canImport(Darwin)
            IO.Event.Kqueue.driver()
        #elseif canImport(Glibc)
            IO.Event.Epoll.driver()
        #elseif os(Windows)
            fatalError("Windows IOCP driver not yet implemented")
        #else
            fatalError("Unsupported platform")
        #endif
    }
}
