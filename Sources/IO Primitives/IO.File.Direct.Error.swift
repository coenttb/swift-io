//
//  IO.File.Direct.Error.swift
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

extension IO.File.Direct {
    /// Errors that can occur during Direct I/O operations.
    public enum Error: Swift.Error, Sendable, Equatable {
        /// Direct I/O is not supported on this platform or filesystem.
        ///
        /// This occurs when:
        /// - Using `.direct` mode on macOS (use `.uncached` instead)
        /// - The filesystem doesn't support `O_DIRECT` or `NO_BUFFERING`
        /// - Requirements are `.unknown` and cannot be determined
        case notSupported

        /// The buffer memory address is not properly aligned.
        ///
        /// Direct I/O requires the buffer to be aligned to the sector size.
        /// Use `Buffer.Aligned` for portable aligned allocation.
        case misalignedBuffer(address: Int, required: Int)

        /// The file offset is not properly aligned.
        ///
        /// Direct I/O requires file offsets to be multiples of the sector size.
        case misalignedOffset(offset: Int64, required: Int)

        /// The I/O length is not a valid multiple of the sector size.
        ///
        /// Direct I/O requires transfer lengths to be exact multiples.
        case invalidLength(length: Int, requiredMultiple: Int)

        /// Failed to enable or disable cache bypass mode.
        case modeChangeFailed

        /// The file handle is not valid or not open for the requested operation.
        case invalidHandle

        /// Platform-specific error with error code.
        case platform(code: Int32, operation: Operation)
    }
}

// MARK: - CustomStringConvertible

extension IO.File.Direct.Error: CustomStringConvertible {
    public var description: String {
        switch self {
        case .notSupported:
            return "Direct I/O not supported"
        case .misalignedBuffer(let address, let required):
            return "Buffer address 0x\(String(address, radix: 16)) not aligned to \(required) bytes"
        case .misalignedOffset(let offset, let required):
            return "File offset \(offset) not aligned to \(required) bytes"
        case .invalidLength(let length, let requiredMultiple):
            return "Length \(length) is not a multiple of \(requiredMultiple)"
        case .modeChangeFailed:
            return "Failed to change cache mode"
        case .invalidHandle:
            return "Invalid file handle"
        case .platform(let code, let operation):
            #if !os(Windows)
                let message = String(cString: strerror(code))
                return "Platform error \(code) during \(operation): \(message)"
            #else
                return "Platform error \(code) during \(operation)"
            #endif
        }
    }
}

// MARK: - Operation

extension IO.File.Direct.Error {
    /// Direct I/O operation types for syscall error context.
    public enum Operation: String, Sendable, Equatable {
        case open
        case setNoCache
        case clearNoCache
        case getSectorSize
        case read
        case write
    }
}

// MARK: - Syscall (Package-Internal Raw Error)

extension IO.File.Direct.Error {
    /// Raw syscall-level error with platform-specific details.
    ///
    /// This type captures the exact errno/win32 error code from syscalls.
    /// It is translated to the semantic `IO.File.Direct.Error` at API boundaries.
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

        /// Alignment validation failed.
        case alignmentViolation(operation: Operation)

        /// Operation not supported on this platform/filesystem.
        case notSupported(operation: Operation)
    }
}

// MARK: - Translation from Syscall

extension IO.File.Direct.Error {
    /// Creates a semantic error from a raw syscall error.
    package init(from syscall: Syscall) {
        switch syscall {
        case .invalidDescriptor:
            self = .invalidHandle

        case .alignmentViolation(let operation):
            // Alignment violation during the operation
            self = .platform(code: -1, operation: operation)

        case .notSupported:
            self = .notSupported

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
            case EINVAL:
                // EINVAL from O_DIRECT often means alignment violation
                return .platform(code: errno, operation: operation)
            case EBADF:
                return .invalidHandle
            case ENOTSUP, EOPNOTSUPP:
                return .notSupported
            case EACCES, EPERM:
                return .platform(code: errno, operation: operation)
            default:
                return .platform(code: errno, operation: operation)
            }
        }
    #endif

    #if os(Windows)
        /// Maps Windows error code to semantic error.
        private static func fromWindowsError(_ error: UInt32, operation: Operation) -> Self {
            switch error {
            case DWORD(ERROR_INVALID_PARAMETER):
                return .platform(code: Int32(error), operation: operation)
            case DWORD(ERROR_INVALID_HANDLE):
                return .invalidHandle
            case DWORD(ERROR_NOT_SUPPORTED):
                return .notSupported
            case DWORD(ERROR_ACCESS_DENIED):
                return .platform(code: Int32(error), operation: operation)
            default:
                return .platform(code: Int32(error), operation: operation)
            }
        }
    #endif
}
