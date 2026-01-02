//
//  IO.File.Open.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 30/12/2025.
//

public import Kernel

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#elseif os(Windows)
    import WinSDK
#endif

// MARK: - Namespace

extension IO.File {
    /// Namespace for file opening types.
    public enum Open {}
}

// MARK: - Options

extension IO.File.Open {
    /// Options for opening a file.
    public struct Options: Sendable, Equatable {
        /// Access mode (read, write, or both).
        ///
        /// Uses `Kernel.File.Open.Mode` directly from swift-kernel.
        public var mode: Kernel.File.Open.Mode

        /// Create the file if it doesn't exist.
        public var create: Bool

        /// Truncate the file to zero length on open.
        public var truncate: Bool

        /// Cache mode (buffered, direct, uncached, or auto).
        public var cache: IO.File.Direct.Mode

        /// Creates default options (read-only, buffered).
        public init() {
            self.mode = .read
            self.create = false
            self.truncate = false
            self.cache = .buffered
        }

        /// Creates options with specific access mode.
        public init(mode: Kernel.File.Open.Mode) {
            self.mode = mode
            self.create = false
            self.truncate = false
            self.cache = .buffered
        }
    }
}

// MARK: - Error

extension IO.File.Open {
    /// Errors that can occur when opening a file.
    public enum Error: Swift.Error, Sendable, Equatable {
        /// The file or directory does not exist.
        case notFound(path: String)

        /// Permission denied.
        case permissionDenied(path: String)

        /// The file already exists (with exclusive creation).
        case alreadyExists(path: String)

        /// The path refers to a directory.
        case isDirectory(path: String)

        /// Too many open files in the system or process.
        case tooManyOpenFiles

        /// Direct I/O is not supported.
        case directNotSupported

        /// Platform-specific error with structured reason.
        case platform(code: Int32, reason: Reason)

        /// Structured reason for platform errors.
        public enum Reason: Sendable, Equatable {
            case loop
            case nameTooLong
            case notEmpty
            case crossDevice
            case invalidHandle
            case interrupted
            case noSpace
            case ioError
            case other
        }
    }
}

// MARK: - Error Construction

extension IO.File.Open.Error {
    #if !os(Windows)
        /// Creates an error from a POSIX errno.
        package init(posixErrno: Int32, path: String) {
            switch posixErrno {
            case ENOENT:
                self = .notFound(path: path)
            case EACCES, EPERM:
                self = .permissionDenied(path: path)
            case EEXIST:
                self = .alreadyExists(path: path)
            case EISDIR:
                self = .isDirectory(path: path)
            case EMFILE, ENFILE:
                self = .tooManyOpenFiles
            case EINVAL:
                self = .directNotSupported
            default:
                self = .platform(code: posixErrno, reason: .other)
            }
        }
    #endif

    #if os(Windows)
        /// Creates an error from a Windows error code.
        package init(windowsError: DWORD, path: String) {
            switch windowsError {
            case DWORD(ERROR_FILE_NOT_FOUND), DWORD(ERROR_PATH_NOT_FOUND):
                self = .notFound(path: path)
            case DWORD(ERROR_ACCESS_DENIED):
                self = .permissionDenied(path: path)
            case DWORD(ERROR_FILE_EXISTS), DWORD(ERROR_ALREADY_EXISTS):
                self = .alreadyExists(path: path)
            case DWORD(ERROR_TOO_MANY_OPEN_FILES):
                self = .tooManyOpenFiles
            case DWORD(ERROR_INVALID_PARAMETER):
                self = .directNotSupported
            default:
                self = .platform(code: Int32(windowsError), reason: .other)
            }
        }
    #endif
}

// MARK: - From Kernel.Open.Error

extension IO.File.Open.Error {
    /// Creates an IO open error from a Kernel open error.
    package init(from error: Kernel.Open.Error, path: String) {
        switch error {
        case .path(let pathError):
            switch pathError {
            case .notFound:
                self = .notFound(path: path)
            case .notDirectory:
                self = .notFound(path: path)
            case .isDirectory:
                self = .isDirectory(path: path)
            case .exists:
                self = .alreadyExists(path: path)
            case .loop:
                self = .platform(code: -1, reason: .loop)
            case .nameTooLong:
                self = .platform(code: -1, reason: .nameTooLong)
            case .notEmpty:
                self = .platform(code: -1, reason: .notEmpty)
            case .crossDevice:
                self = .platform(code: -1, reason: .crossDevice)
            }

        case .permission(let permError):
            switch permError {
            case .denied, .notPermitted, .readOnlyFilesystem:
                self = .permissionDenied(path: path)
            }

        case .handle(let handleError):
            switch handleError {
            case .invalid:
                self = .platform(code: -1, reason: .invalidHandle)
            case .processLimit, .systemLimit:
                self = .tooManyOpenFiles
            }

        case .signal:
            self = .platform(code: -1, reason: .interrupted)

        case .space:
            self = .platform(code: -1, reason: .noSpace)

        case .io:
            self = .platform(code: -1, reason: .ioError)

        case .platform:
            self = .platform(code: -1, reason: .other)
        }
    }
}

// MARK: - CustomStringConvertible

extension IO.File.Open.Error: CustomStringConvertible {
    public var description: String {
        switch self {
        case .notFound(let path):
            return "File not found: \(path)"
        case .permissionDenied(let path):
            return "Permission denied: \(path)"
        case .alreadyExists(let path):
            return "File already exists: \(path)"
        case .isDirectory(let path):
            return "Is a directory: \(path)"
        case .tooManyOpenFiles:
            return "Too many open files"
        case .directNotSupported:
            return "Direct I/O not supported"
        case .platform(let code, let reason):
            let reasonDescription: String
            switch reason {
            case .loop: reasonDescription = "Symbolic link loop"
            case .nameTooLong: reasonDescription = "Path too long"
            case .notEmpty: reasonDescription = "Directory not empty"
            case .crossDevice: reasonDescription = "Cross-device operation"
            case .invalidHandle: reasonDescription = "Invalid handle"
            case .interrupted: reasonDescription = "Interrupted by signal"
            case .noSpace: reasonDescription = "No space left"
            case .ioError: reasonDescription = "I/O error"
            case .other:
                #if !os(Windows)
                    if code >= 0 {
                        reasonDescription = String(cString: strerror(code))
                    } else {
                        reasonDescription = "Unknown error"
                    }
                #else
                    reasonDescription = "Windows error"
                #endif
            }
            return "Platform error \(code): \(reasonDescription)"
        }
    }
}
