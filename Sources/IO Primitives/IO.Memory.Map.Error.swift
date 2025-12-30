//
//  IO.Memory.Map.Error.swift
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

extension IO.Memory.Map {
    /// Errors that can occur during memory mapping operations.
    ///
    /// These errors are operation-level failures, not lifecycle concerns.
    /// Lifecycle errors (shutdown, cancellation) are handled by `IO.Lifecycle.Error`.
    public enum Error: Swift.Error, Sendable, Equatable {
        /// The requested operation is not supported on this platform or configuration.
        case unsupported

        /// The requested range is invalid (e.g., extends beyond file size).
        case invalidRange

        /// The offset or length is not properly aligned.
        case invalidAlignment

        /// Permission denied for the requested access mode.
        case permissionDenied

        /// Insufficient memory to create the mapping.
        case outOfMemory

        /// The file is too small for the requested mapping.
        case fileTooSmall

        /// The requested mapping size exceeds system limits.
        case mappingSizeLimit

        /// The access/sharing/safety combination is not supported.
        case unsupportedConfiguration

        /// The file handle is invalid or closed.
        case invalidHandle

        /// The mapping operation is not supported on this file type.
        case unsupportedFileType

        /// The mapping was previously unmapped and cannot be used.
        case alreadyUnmapped

        /// Platform-specific error with error code.
        case platform(code: Int32, message: String)
    }
}

// MARK: - Operation

extension IO.Memory.Map.Error {
    /// Memory mapping operation types.
    ///
    /// Used by both semantic errors and syscall errors to identify
    /// which operation failed.
    package enum Operation: Sendable, Equatable {
        case map
        case unmap
        case protect
        case sync
        case advise
    }
}

// MARK: - Syscall (Package-Internal Raw Error)

extension IO.Memory.Map.Error {
    /// Raw syscall-level error with platform-specific details.
    ///
    /// This type captures the exact errno/win32 error code from syscalls.
    /// It is translated to the semantic `IO.Memory.Map.Error` at API boundaries.
    ///
    /// - Note: Package-internal. Not exposed to library consumers.
    package enum Syscall: Swift.Error, Sendable, Equatable {
        #if !os(Windows)
        /// POSIX syscall failure with errno.
        case posix(errno: Int32, operation: Operation)
        #endif

        #if os(Windows)
        /// Windows syscall failure with error code.
        case windows(code: UInt32, operation: Operation)
        #endif

        /// Invalid file handle provided.
        case invalidHandle(operation: Operation)

        /// Invalid length (zero or negative).
        case invalidLength(operation: Operation)

        /// Invalid alignment for offset or buffer.
        case invalidAlignment(operation: Operation)
    }
}

// MARK: - CustomStringConvertible

extension IO.Memory.Map.Error: CustomStringConvertible {
    public var description: String {
        switch self {
        case .unsupported:
            return "Memory mapping not supported"
        case .invalidRange:
            return "Invalid mapping range"
        case .invalidAlignment:
            return "Invalid alignment"
        case .permissionDenied:
            return "Permission denied"
        case .outOfMemory:
            return "Out of memory"
        case .fileTooSmall:
            return "File too small for requested mapping"
        case .mappingSizeLimit:
            return "Mapping size exceeds system limit"
        case .unsupportedConfiguration:
            return "Unsupported access/sharing/safety configuration"
        case .invalidHandle:
            return "Invalid file handle"
        case .unsupportedFileType:
            return "Unsupported file type for mapping"
        case .alreadyUnmapped:
            return "Mapping already unmapped"
        case .platform(let code, let message):
            return "Platform error \(code): \(message)"
        }
    }
}

// MARK: - Translation from Syscall

extension IO.Memory.Map.Error {
    /// Creates a semantic error from a raw syscall error.
    ///
    /// This is the single, auditable translation table from platform
    /// errors to portable semantic errors.
    package init(from syscall: Syscall) {
        switch syscall {
        case .invalidHandle:
            self = .invalidHandle
        case .invalidLength:
            self = .invalidRange
        case .invalidAlignment:
            self = .invalidAlignment

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
        case EACCES, EPERM:
            return .permissionDenied
        case EINVAL:
            return .invalidAlignment
        case ENOMEM:
            return .outOfMemory
        case ENODEV:
            return .unsupportedFileType
        case EBADF:
            return .invalidHandle
        case ENXIO:
            return .invalidRange
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
        case DWORD(ERROR_ACCESS_DENIED):
            return .permissionDenied
        case DWORD(ERROR_INVALID_PARAMETER):
            return .invalidAlignment
        case DWORD(ERROR_NOT_ENOUGH_MEMORY), DWORD(ERROR_OUTOFMEMORY):
            return .outOfMemory
        case DWORD(ERROR_INVALID_HANDLE):
            return .invalidHandle
        case DWORD(ERROR_FILE_INVALID):
            return .unsupportedFileType
        default:
            return .platform(code: Int32(error), message: "\(operation): Windows error")
        }
    }
    #endif
}
