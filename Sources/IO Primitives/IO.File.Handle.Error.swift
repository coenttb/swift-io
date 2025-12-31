//
//  IO.File.Handle.Error.swift
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

extension IO.File.Handle {
    /// Errors that can occur during file handle operations.
    public enum Error: Swift.Error, Sendable, Equatable {
        /// The file handle is invalid or closed.
        case invalidHandle

        /// End of file reached.
        case endOfFile

        /// The operation was interrupted.
        case interrupted

        /// No space left on device.
        case noSpace

        /// Buffer alignment violation for Direct I/O (detected by pre-validation).
        case misalignedBuffer(address: Int, required: Int)

        /// Offset alignment violation for Direct I/O (detected by pre-validation).
        case misalignedOffset(offset: Int64, required: Int)

        /// Length not a multiple of required granularity (detected by pre-validation).
        case invalidLength(length: Int, requiredMultiple: Int)

        /// Direct I/O requirements are unknown.
        case requirementsUnknown

        /// Alignment violation or Direct I/O not supported (detected by kernel).
        ///
        /// This error occurs when the kernel rejects an I/O operation with `EINVAL`
        /// (POSIX) or `ERROR_INVALID_PARAMETER` (Windows). In Direct I/O mode,
        /// this typically indicates:
        ///
        /// - Buffer address not aligned to required boundary
        /// - File offset not aligned
        /// - Transfer length not a multiple of sector/block size
        /// - Direct I/O not supported by the filesystem/device
        ///
        /// **Note:** This error may occur even if pre-validation passed, because
        /// alignment requirements are not always reliably discoverable, especially
        /// on Linux. See `IO.File.Direct.requirements(for:)` documentation.
        case alignmentViolation(operation: Operation)

        /// Platform-specific error.
        case platform(code: Int32, operation: Operation)
    }

    /// Operation type for error context.
    public enum Operation: String, Sendable {
        case read
        case write
        case seek
        case sync
    }
}

// MARK: - Error Construction

extension IO.File.Handle.Error {
    #if !os(Windows)
    /// Creates an error from a POSIX errno.
    package init(posixErrno: Int32, operation: IO.File.Handle.Operation) {
        switch posixErrno {
        case EBADF:
            self = .invalidHandle
        case EINTR:
            self = .interrupted
        case ENOSPC:
            self = .noSpace
        case EINVAL:
            // EINVAL during I/O typically means alignment violation for Direct I/O
            // or unsupported operation. Map to semantic error for stable diagnostics.
            self = .alignmentViolation(operation: operation)
        default:
            self = .platform(code: posixErrno, operation: operation)
        }
    }
    #endif

    #if os(Windows)
    /// Creates an error from a Windows error code.
    package init(windowsError: DWORD, operation: IO.File.Handle.Operation) {
        switch windowsError {
        case DWORD(ERROR_INVALID_HANDLE):
            self = .invalidHandle
        case DWORD(ERROR_DISK_FULL), DWORD(ERROR_HANDLE_DISK_FULL):
            self = .noSpace
        case DWORD(ERROR_INVALID_PARAMETER):
            // ERROR_INVALID_PARAMETER during I/O typically means alignment violation
            // for FILE_FLAG_NO_BUFFERING. Map to semantic error.
            self = .alignmentViolation(operation: operation)
        default:
            self = .platform(code: Int32(windowsError), operation: operation)
        }
    }
    #endif
}

// MARK: - From Direct Error

extension IO.File.Handle.Error {
    /// Creates a handle error from a Direct I/O error.
    package init(from directError: IO.File.Direct.Error) {
        switch directError {
        case .notSupported:
            self = .requirementsUnknown
        case .misalignedBuffer(let address, let required):
            self = .misalignedBuffer(address: address, required: required)
        case .misalignedOffset(let offset, let required):
            self = .misalignedOffset(offset: offset, required: required)
        case .invalidLength(let length, let requiredMultiple):
            self = .invalidLength(length: length, requiredMultiple: requiredMultiple)
        case .modeChangeFailed:
            self = .platform(code: -1, operation: .sync)
        case .invalidHandle:
            self = .invalidHandle
        case .platform(let code, let operation):
            // Map Direct.Error operation to Handle.Error operation
            switch operation {
            case .open:
                self = .platform(code: code, operation: .read)
            case .setNoCache, .clearNoCache, .getSectorSize:
                self = .platform(code: code, operation: .sync)
            case .read:
                self = .platform(code: code, operation: .read)
            case .write:
                self = .platform(code: code, operation: .write)
            }
        }
    }
}

// MARK: - From Kernel.Read.Error

extension IO.File.Handle.Error {
    /// Creates an IO handle error from a Kernel read error.
    package init(from error: Kernel.Read.Error, operation: IO.File.Handle.Operation) {
        switch error {
        case .handle(let handleError):
            switch handleError {
            case .invalid, .processLimit, .systemLimit:
                self = .invalidHandle
            }

        case .signal:
            self = .interrupted

        case .blocking:
            self = .platform(code: -1, operation: operation)

        case .io:
            self = .platform(code: -1, operation: operation)

        case .memory:
            self = .alignmentViolation(operation: operation)

        case .platform:
            self = .platform(code: -1, operation: operation)
        }
    }
}

// MARK: - From Kernel.Write.Error

extension IO.File.Handle.Error {
    /// Creates an IO handle error from a Kernel write error.
    package init(from error: Kernel.Write.Error, operation: IO.File.Handle.Operation) {
        switch error {
        case .handle(let handleError):
            switch handleError {
            case .invalid, .processLimit, .systemLimit:
                self = .invalidHandle
            }

        case .signal:
            self = .interrupted

        case .blocking:
            self = .platform(code: -1, operation: operation)

        case .io:
            self = .platform(code: -1, operation: operation)

        case .space(let spaceError):
            switch spaceError {
            case .exhausted, .quota:
                self = .noSpace
            }

        case .memory:
            self = .alignmentViolation(operation: operation)

        case .platform:
            self = .platform(code: -1, operation: operation)
        }
    }
}

// MARK: - CustomStringConvertible

extension IO.File.Handle.Error: CustomStringConvertible {
    public var description: String {
        switch self {
        case .invalidHandle:
            return "Invalid file handle"
        case .endOfFile:
            return "End of file"
        case .interrupted:
            return "Operation interrupted"
        case .noSpace:
            return "No space left on device"
        case .misalignedBuffer(let address, let required):
            return "Buffer address 0x\(String(address, radix: 16)) not aligned to \(required) bytes"
        case .misalignedOffset(let offset, let required):
            return "File offset \(offset) not aligned to \(required) bytes"
        case .invalidLength(let length, let requiredMultiple):
            return "Length \(length) is not a multiple of \(requiredMultiple)"
        case .requirementsUnknown:
            return "Direct I/O requirements unknown"
        case .alignmentViolation(let operation):
            return "Alignment violation or Direct I/O not supported during \(operation.rawValue)"
        case .platform(let code, let operation):
            #if !os(Windows)
            let message = String(cString: strerror(code))
            return "Platform error \(code) during \(operation.rawValue): \(message)"
            #else
            return "Platform error \(code) during \(operation.rawValue)"
            #endif
        }
    }
}
