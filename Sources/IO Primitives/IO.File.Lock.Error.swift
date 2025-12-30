//
//  IO.File.Lock.Error.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 30/12/2025.
//

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#elseif os(Windows)
    import WinSDK
#endif

extension IO.File.Lock {
    /// Errors that can occur during file locking operations.
    public enum Error: Swift.Error, Sendable, Equatable {
        /// The lock could not be acquired without blocking.
        ///
        /// Returned when using `.try` acquisition mode and the lock is held.
        case wouldBlock

        /// The operation was interrupted by a signal.
        case interrupted

        /// The requested range is invalid.
        case invalidRange

        /// File locking is not supported on this file or filesystem.
        case notSupported

        /// Permission denied for the requested lock operation.
        case permissionDenied

        /// The file descriptor is invalid or closed.
        case invalidDescriptor

        /// A deadlock was detected.
        case deadlock

        /// The operation timed out (for deadline-based acquisition).
        case timedOut

        /// Platform-specific error with error code.
        case platform(code: Int32, message: String)
    }
}

// MARK: - Operation

extension IO.File.Lock.Error {
    /// File locking operation types.
    package enum Operation: Sendable, Equatable {
        case lock
        case unlock
        case tryLock
    }
}

// MARK: - Syscall (Package-Internal Raw Error)

extension IO.File.Lock.Error {
    /// Raw syscall-level error with platform-specific details.
    ///
    /// This type captures the exact errno/win32 error code from syscalls.
    /// It is translated to the semantic `IO.File.Lock.Error` at API boundaries.
    package enum Syscall: Swift.Error, Sendable, Equatable {
        #if !os(Windows)
        /// POSIX syscall failure with errno.
        case posix(errno: Int32, operation: Operation)
        #endif

        #if os(Windows)
        /// Windows syscall failure with error code.
        case windows(code: UInt32, operation: Operation)
        #endif

        /// Invalid file descriptor provided.
        case invalidDescriptor(operation: Operation)

        /// Invalid range parameters.
        case invalidRange(operation: Operation)
    }
}

// MARK: - CustomStringConvertible

extension IO.File.Lock.Error: CustomStringConvertible {
    public var description: String {
        switch self {
        case .wouldBlock:
            return "Lock would block"
        case .interrupted:
            return "Operation interrupted"
        case .invalidRange:
            return "Invalid lock range"
        case .notSupported:
            return "File locking not supported"
        case .permissionDenied:
            return "Permission denied"
        case .invalidDescriptor:
            return "Invalid file descriptor"
        case .deadlock:
            return "Deadlock detected"
        case .timedOut:
            return "Lock acquisition timed out"
        case .platform(let code, let message):
            return "Platform error \(code): \(message)"
        }
    }
}

// MARK: - Translation from Syscall

extension IO.File.Lock.Error {
    /// Creates a semantic error from a raw syscall error.
    package init(from syscall: Syscall) {
        switch syscall {
        case .invalidDescriptor:
            self = .invalidDescriptor
        case .invalidRange:
            self = .invalidRange

        #if !os(Windows)
        case .posix(let errno, let operation):
            self = Self.fromPosixErrno(errno, operation: operation)
        #endif

        #if os(Windows)
        case .windows(let code, let operation):
            self = Self.fromWindowsError(code, operation: operation)
        #endif
        }
    }

    #if !os(Windows)
    /// Maps POSIX errno to semantic error.
    private static func fromPosixErrno(_ errno: Int32, operation: Operation) -> Self {
        switch errno {
        case EAGAIN, EACCES:
            // EAGAIN/EACCES from fcntl F_SETLK means lock is held by another process
            return .wouldBlock
        case EINTR:
            return .interrupted
        case EINVAL:
            return .invalidRange
        case EBADF:
            return .invalidDescriptor
        case ENOLCK:
            return .notSupported
        case EDEADLK:
            return .deadlock
        default:
            let message = String(cString: strerror(errno))
            return .platform(code: errno, message: "\(operation): \(message)")
        }
    }
    #endif

    #if os(Windows)
    /// Maps Windows error code to semantic error.
    private static func fromWindowsError(_ error: UInt32, operation: Operation) -> Self {
        switch error {
        case DWORD(ERROR_LOCK_VIOLATION), DWORD(ERROR_SHARING_VIOLATION):
            return .wouldBlock
        case DWORD(ERROR_ACCESS_DENIED):
            return .permissionDenied
        case DWORD(ERROR_INVALID_HANDLE):
            return .invalidDescriptor
        case DWORD(ERROR_NOT_LOCKED):
            // Trying to unlock a region that isn't locked
            return .invalidRange
        case DWORD(ERROR_LOCK_FAILED):
            return .wouldBlock
        default:
            return .platform(code: Int32(error), message: "\(operation): Windows error")
        }
    }
    #endif
}
