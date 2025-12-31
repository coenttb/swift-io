//
//  IO.Event.Syscalls.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 31/12/2025.
//

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#elseif os(Windows)
    import WinSDK
#endif

/// Centralized platform syscall shims for IO.Event module.
///
/// ## Design
/// This namespace centralizes all platform-conditional syscall wrappers.
/// Callers should use these methods instead of direct `#if` conditionals.
///
/// ## Platform Abstraction
/// - Darwin: Uses Darwin module
/// - Linux: Uses Glibc module
/// - Windows: Uses WinSDK (sockets only)
extension IO.Event {
    enum Syscalls {
        /// Platform-agnostic read syscall.
        ///
        /// - Parameters:
        ///   - fd: File descriptor to read from.
        ///   - buf: Buffer to read into.
        ///   - count: Maximum bytes to read.
        /// - Returns: Bytes read, or -1 on error.
        static func read(_ fd: Int32, _ buf: UnsafeMutableRawPointer?, _ count: Int) -> Int {
            #if canImport(Darwin)
                Darwin.read(fd, buf, count)
            #elseif canImport(Glibc)
                Glibc.read(fd, buf, count)
            #else
                #error("Unsupported platform")
            #endif
        }

        /// Platform-agnostic write syscall.
        ///
        /// - Parameters:
        ///   - fd: File descriptor to write to.
        ///   - buf: Buffer to write from.
        ///   - count: Maximum bytes to write.
        /// - Returns: Bytes written, or -1 on error.
        static func write(_ fd: Int32, _ buf: UnsafeRawPointer?, _ count: Int) -> Int {
            #if canImport(Darwin)
                Darwin.write(fd, buf, count)
            #elseif canImport(Glibc)
                Glibc.write(fd, buf, count)
            #else
                #error("Unsupported platform")
            #endif
        }

        /// Platform-agnostic shutdown syscall.
        ///
        /// - Parameters:
        ///   - fd: Socket file descriptor.
        ///   - how: Shutdown mode (SHUT_RD, SHUT_WR, SHUT_RDWR).
        /// - Returns: 0 on success, -1 on error.
        static func shutdown(_ fd: Int32, _ how: Int32) -> Int32 {
            #if canImport(Darwin)
                Darwin.shutdown(fd, how)
            #elseif canImport(Glibc)
                Glibc.shutdown(fd, how)
            #else
                #error("Unsupported platform")
            #endif
        }

        /// Platform-agnostic close syscall.
        ///
        /// - Parameter fd: File descriptor to close.
        /// - Returns: 0 on success, -1 on error.
        static func close(_ fd: Int32) -> Int32 {
            #if canImport(Darwin)
                Darwin.close(fd)
            #elseif canImport(Glibc)
                Glibc.close(fd)
            #else
                #error("Unsupported platform")
            #endif
        }
    }
}
