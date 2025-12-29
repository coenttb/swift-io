//
//  IO.NonBlocking.Driver+Platform.swift
//  swift-io
//
//  Platform-specific driver selection.
//

#if canImport(Darwin)
import IO_NonBlocking_Kqueue
#endif

extension IO.NonBlocking.Driver {
    /// The platform-appropriate driver for the current operating system.
    ///
    /// Selects the best available event notification mechanism:
    /// - **Darwin (macOS/iOS)**: kqueue
    /// - **Linux**: epoll (when implemented)
    /// - **Windows**: IOCP (when implemented)
    ///
    /// ## Usage
    /// ```swift
    /// let selector = try await IO.NonBlocking.Selector.make(driver: .platform)
    /// ```
    public static var platform: IO.NonBlocking.Driver {
        #if canImport(Darwin)
        IO.NonBlocking.Kqueue.driver()
        #elseif canImport(Glibc)
        fatalError("Linux epoll driver not yet implemented")
        #elseif os(Windows)
        fatalError("Windows IOCP driver not yet implemented")
        #else
        fatalError("Unsupported platform")
        #endif
    }
}
