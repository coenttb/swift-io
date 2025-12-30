//
//  IO.File.Syscalls.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 30/12/2025.
//
//  Platform-specific syscall wrappers for file operations.
//

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif os(Windows)
import WinSDK
#endif

extension IO.File {
    /// Low-level syscall wrappers for file operations.
    ///
    /// These are package-internal primitives. Use `IO.File.open` and
    /// `IO.File.Handle` for the public API.
    package enum Syscalls {}
}

// MARK: - Open Flags

extension IO.File.Syscalls {
    /// Computes platform-specific open flags.
    ///
    /// - Parameters:
    ///   - access: Read/write access mode.
    ///   - create: Create file if it doesn't exist.
    ///   - truncate: Truncate file to zero length.
    ///   - direct: Use Direct I/O (O_DIRECT on Linux).
    /// - Returns: Platform-specific flags value.
    #if !os(Windows)
    package static func openFlags(
        access: IO.File.Access,
        create: Bool,
        truncate: Bool,
        direct: Bool
    ) -> Int32 {
        var flags: Int32 = 0

        // Access mode
        switch (access.contains(.read), access.contains(.write)) {
        case (true, true):
            flags |= O_RDWR
        case (false, true):
            flags |= O_WRONLY
        case (true, false), (false, false):
            flags |= O_RDONLY
        }

        // Options
        if create {
            flags |= O_CREAT
        }
        if truncate {
            flags |= O_TRUNC
        }

        // Direct I/O (Linux only; macOS uses fcntl post-open)
        #if os(Linux)
        if direct {
            flags |= O_DIRECT
        }
        #endif

        // Always set close-on-exec for safety
        flags |= O_CLOEXEC

        return flags
    }
    #endif

    #if os(Windows)
    package static func openFlags(
        access: IO.File.Access,
        create: Bool,
        truncate: Bool,
        direct: Bool
    ) -> (desiredAccess: DWORD, creationDisposition: DWORD, flagsAndAttributes: DWORD) {
        var desiredAccess: DWORD = 0
        var creationDisposition: DWORD = 0
        var flagsAndAttributes: DWORD = DWORD(FILE_ATTRIBUTE_NORMAL)

        // Access mode
        if access.contains(.read) {
            desiredAccess |= DWORD(GENERIC_READ)
        }
        if access.contains(.write) {
            desiredAccess |= DWORD(GENERIC_WRITE)
        }
        if desiredAccess == 0 {
            desiredAccess = DWORD(GENERIC_READ)
        }

        // Creation disposition
        if create && truncate {
            creationDisposition = DWORD(CREATE_ALWAYS)
        } else if create {
            creationDisposition = DWORD(OPEN_ALWAYS)
        } else if truncate {
            creationDisposition = DWORD(TRUNCATE_EXISTING)
        } else {
            creationDisposition = DWORD(OPEN_EXISTING)
        }

        // Direct I/O
        if direct {
            flagsAndAttributes |= DWORD(FILE_FLAG_NO_BUFFERING)
        }

        return (desiredAccess, creationDisposition, flagsAndAttributes)
    }
    #endif
}

// MARK: - Open

extension IO.File.Syscalls {
    /// Opens a file and returns the raw descriptor.
    ///
    /// - Parameters:
    ///   - path: The file path.
    ///   - flags: Platform-specific flags from `openFlags`.
    /// - Returns: The file descriptor.
    /// - Throws: `IO.File.Open.Error` on failure.
    #if !os(Windows)
    package static func open(
        path: String,
        flags: Int32
    ) throws(IO.File.Open.Error) -> IO.File.Descriptor {
        // Default permissions for new files: 0644
        let mode: mode_t = S_IRUSR | S_IWUSR | S_IRGRP | S_IROTH

        let fd = path.withCString { cPath in
            #if canImport(Darwin)
            Darwin.open(cPath, flags, mode)
            #else
            Glibc.open(cPath, flags, mode)
            #endif
        }

        guard fd >= 0 else {
            throw IO.File.Open.Error(posixErrno: errno, path: path)
        }

        return fd
    }
    #endif

    #if os(Windows)
    package static func open(
        path: String,
        desiredAccess: DWORD,
        creationDisposition: DWORD,
        flagsAndAttributes: DWORD
    ) throws(IO.File.Open.Error) -> IO.File.Descriptor {
        let handle = path.withCString(encodedAs: UTF16.self) { cPath in
            CreateFileW(
                cPath,
                desiredAccess,
                DWORD(FILE_SHARE_READ | FILE_SHARE_WRITE),
                nil,
                creationDisposition,
                flagsAndAttributes,
                nil
            )
        }

        guard handle != INVALID_HANDLE_VALUE else {
            throw IO.File.Open.Error(windowsError: GetLastError(), path: path)
        }

        return handle
    }
    #endif
}

// MARK: - Close

extension IO.File.Syscalls {
    /// Closes a file descriptor.
    ///
    /// Treats EINTR as "closed" per POSIX.1-2008 semantics.
    #if !os(Windows)
    package static func close(_ descriptor: IO.File.Descriptor) {
        #if canImport(Darwin)
        let result = Darwin.close(descriptor)
        #else
        let result = Glibc.close(descriptor)
        #endif
        // EINTR means fd is closed but cleanup may be incomplete
        // The fd is invalid regardless, so we don't retry
        _ = result
    }
    #endif

    #if os(Windows)
    package static func close(_ handle: IO.File.Descriptor) {
        if handle != INVALID_HANDLE_VALUE {
            _ = CloseHandle(handle)
        }
    }
    #endif
}

// MARK: - Positional Read/Write

extension IO.File.Syscalls {
    /// Reads from a file at a specific offset without changing the file position.
    #if !os(Windows)
    package static func pread(
        _ descriptor: IO.File.Descriptor,
        into buffer: UnsafeMutableRawPointer,
        count: Int,
        offset: Int64
    ) throws(IO.File.Handle.Error) -> Int {
        #if canImport(Darwin)
        let result = Darwin.pread(descriptor, buffer, count, off_t(offset))
        #else
        let result = Glibc.pread(descriptor, buffer, count, off_t(offset))
        #endif
        guard result >= 0 else {
            throw IO.File.Handle.Error(posixErrno: errno, operation: .read)
        }
        return result
    }
    #endif

    #if os(Windows)
    package static func pread(
        _ handle: IO.File.Descriptor,
        into buffer: UnsafeMutableRawPointer,
        count: Int,
        offset: Int64
    ) throws(IO.File.Handle.Error) -> Int {
        var overlapped = OVERLAPPED()
        overlapped.Offset = DWORD(offset & 0xFFFFFFFF)
        overlapped.OffsetHigh = DWORD(offset >> 32)

        var bytesRead: DWORD = 0
        let result = ReadFile(
            handle,
            buffer,
            DWORD(count),
            &bytesRead,
            &overlapped
        )

        guard result != 0 else {
            throw IO.File.Handle.Error(windowsError: GetLastError(), operation: .read)
        }

        return Int(bytesRead)
    }
    #endif

    /// Writes to a file at a specific offset without changing the file position.
    #if !os(Windows)
    package static func pwrite(
        _ descriptor: IO.File.Descriptor,
        from buffer: UnsafeRawPointer,
        count: Int,
        offset: Int64
    ) throws(IO.File.Handle.Error) -> Int {
        #if canImport(Darwin)
        let result = Darwin.pwrite(descriptor, buffer, count, off_t(offset))
        #else
        let result = Glibc.pwrite(descriptor, buffer, count, off_t(offset))
        #endif
        guard result >= 0 else {
            throw IO.File.Handle.Error(posixErrno: errno, operation: .write)
        }
        return result
    }
    #endif

    #if os(Windows)
    package static func pwrite(
        _ handle: IO.File.Descriptor,
        from buffer: UnsafeRawPointer,
        count: Int,
        offset: Int64
    ) throws(IO.File.Handle.Error) -> Int {
        var overlapped = OVERLAPPED()
        overlapped.Offset = DWORD(offset & 0xFFFFFFFF)
        overlapped.OffsetHigh = DWORD(offset >> 32)

        var bytesWritten: DWORD = 0
        let result = WriteFile(
            handle,
            buffer,
            DWORD(count),
            &bytesWritten,
            &overlapped
        )

        guard result != 0 else {
            throw IO.File.Handle.Error(windowsError: GetLastError(), operation: .write)
        }

        return Int(bytesWritten)
    }
    #endif
}
