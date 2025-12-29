//
//  IO.NonBlocking.Error.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 28/12/2025.
//

extension IO.NonBlocking {
    /// Leaf errors for non-blocking I/O operations.
    ///
    /// These are operational failures at the I/O boundary. Lifecycle concerns
    /// (shutdown, cancellation) are wrapped in `IO.Lifecycle.Error<Error>`.
    ///
    /// ## Error Categories
    /// - **Platform errors**: Direct OS error codes (`errno` or Win32)
    /// - **Descriptor errors**: Invalid or misused descriptors
    /// - **Half-close errors**: Operations on closed sides
    ///
    /// ## Usage
    /// ```swift
    /// func operation() async throws(IO.Lifecycle.Error<IO.NonBlocking.Error>)
    /// ```
    ///
    /// ## Note on `wouldBlock`
    /// The `wouldBlock` error is **internal only** and never exposed publicly.
    /// It is consumed by retry loops and converted to "wait for readiness".
    public enum Error: Swift.Error, Sendable, Equatable {
        // MARK: - Platform Errors

        /// Unix/POSIX error from `errno`.
        case platform(errno: Int32)

        /// Windows error from `GetLastError()` or `WSAGetLastError()`.
        case platformWindows(code: UInt32)

        // MARK: - Descriptor Errors

        /// The descriptor is invalid (closed, not a socket, etc.).
        case invalidDescriptor

        /// The descriptor is already registered with this selector.
        case alreadyRegistered

        /// The descriptor is not registered with this selector.
        case notRegistered

        // MARK: - Half-Close Errors

        /// Read operation after the read side was closed.
        ///
        /// Note: In practice, reads after `shutdownRead()` return 0 (EOF)
        /// rather than throwing. This error is for protocol violations.
        case readClosed

        /// Write operation after the write side was closed.
        case writeClosed
    }
}

// MARK: - CustomStringConvertible

extension IO.NonBlocking.Error: CustomStringConvertible {
    public var description: String {
        switch self {
        case .platform(let errno):
            return "Platform error (errno: \(errno))"
        case .platformWindows(let code):
            return "Windows error (code: \(code))"
        case .invalidDescriptor:
            return "Invalid descriptor"
        case .alreadyRegistered:
            return "Already registered"
        case .notRegistered:
            return "Not registered"
        case .readClosed:
            return "Read side closed"
        case .writeClosed:
            return "Write side closed"
        }
    }
}
