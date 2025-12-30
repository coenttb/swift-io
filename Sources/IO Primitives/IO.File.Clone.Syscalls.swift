//
//  IO.File.Clone.Syscalls.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 30/12/2025.
//
//  Platform-specific syscall wrappers for file cloning.
//

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif os(Windows)
import WinSDK
#endif

// MARK: - macOS Implementation

#if os(macOS)
extension IO.File.Clone {
    /// Attempts to clone a file using clonefile().
    ///
    /// - Parameters:
    ///   - source: Source file path.
    ///   - destination: Destination file path.
    /// - Returns: `true` if cloned, `false` if not supported.
    /// - Throws: `SyscallError` for other errors.
    package static func clonefileAttempt(
        source: String,
        destination: String
    ) throws(SyscallError) -> Bool {
        let result = source.withCString { src in
            destination.withCString { dst in
                clonefile(src, dst, 0)
            }
        }

        if result == 0 {
            return true
        }

        let err = errno
        // ENOTSUP means filesystem doesn't support cloning
        if err == ENOTSUP {
            return false
        }

        throw .posix(errno: err, operation: .clonefile)
    }

    /// Copies a file using copyfile() with COPYFILE_CLONE flag.
    ///
    /// This attempts CoW clone first, falls back to copy.
    package static func copyfileClone(
        source: String,
        destination: String
    ) throws(SyscallError) {
        // Check if destination exists first (copyfile doesn't fail by default)
        var statBuf = Darwin.stat()
        let destExists = destination.withCString { stat($0, &statBuf) } == 0
        if destExists {
            throw .posix(errno: EEXIST, operation: .copyfile)
        }

        let result = source.withCString { src in
            destination.withCString { dst in
                copyfile(src, dst, nil, copyfile_flags_t(COPYFILE_CLONE | COPYFILE_ALL))
            }
        }

        guard result == 0 else {
            throw .posix(errno: errno, operation: .copyfile)
        }
    }

    /// Copies a file using copyfile() without clone attempt.
    package static func copyfileData(
        source: String,
        destination: String
    ) throws(SyscallError) {
        // Check if destination exists first (copyfile doesn't fail by default)
        var statBuf = Darwin.stat()
        let destExists = destination.withCString { stat($0, &statBuf) } == 0
        if destExists {
            throw .posix(errno: EEXIST, operation: .copyfile)
        }

        let result = source.withCString { src in
            destination.withCString { dst in
                copyfile(src, dst, nil, copyfile_flags_t(COPYFILE_DATA))
            }
        }

        guard result == 0 else {
            throw .posix(errno: errno, operation: .copyfile)
        }
    }

    /// Probes whether the filesystem at the given path supports cloning.
    package static func probeCapability(at path: String) throws(SyscallError) -> Capability {
        var statfsBuf = Darwin.statfs()
        let result = path.withCString { p in
            statfs(p, &statfsBuf)
        }

        guard result == 0 else {
            throw .posix(errno: errno, operation: .statfs)
        }

        // APFS filesystem type
        let fsType = withUnsafeBytes(of: statfsBuf.f_fstypename) { buf in
            String(cString: buf.bindMemory(to: CChar.self).baseAddress!)
        }

        // APFS supports cloning
        if fsType == "apfs" {
            return .reflink
        }

        return .none
    }
}
#endif

// MARK: - Linux Implementation

#if os(Linux)
// ioctl request code for FICLONE
private let FICLONE: UInt = 0x40049409

extension IO.File.Clone {
    /// Attempts to clone a file using ioctl(FICLONE).
    ///
    /// - Parameters:
    ///   - sourceFd: Source file descriptor.
    ///   - destFd: Destination file descriptor.
    /// - Returns: `true` if cloned, `false` if not supported.
    /// - Throws: `SyscallError` for other errors.
    package static func ficloneAttempt(
        sourceFd: Int32,
        destFd: Int32
    ) throws(SyscallError) -> Bool {
        let result = ioctl(destFd, FICLONE, sourceFd)

        if result == 0 {
            return true
        }

        let err = errno
        // EOPNOTSUPP/ENOTSUP means filesystem doesn't support cloning
        if err == EOPNOTSUPP || err == ENOTSUP || err == EINVAL || err == EXDEV {
            return false
        }

        throw .posix(errno: err, operation: .ficlone)
    }

    /// Copies file data using copy_file_range().
    ///
    /// This may use server-side copy or reflink on supported filesystems.
    package static func copyFileRange(
        sourceFd: Int32,
        destFd: Int32,
        length: Int
    ) throws(SyscallError) {
        var remaining = length
        var srcOffset: off_t = 0
        var dstOffset: off_t = 0

        while remaining > 0 {
            let copied = copy_file_range(
                sourceFd, &srcOffset,
                destFd, &dstOffset,
                remaining, 0
            )

            if copied < 0 {
                throw .posix(errno: errno, operation: .copyFileRange)
            }

            if copied == 0 {
                break // EOF
            }

            remaining -= Int(copied)
        }
    }

    /// Probes whether the filesystem at the given path supports cloning.
    package static func probeCapability(at path: String) throws(SyscallError) -> Capability {
        var statfsBuf = statfs()
        let result = path.withCString { p in
            Glibc.statfs(p, &statfsBuf)
        }

        guard result == 0 else {
            throw .posix(errno: errno, operation: .statfs)
        }

        // Known filesystems that support FICLONE
        // Btrfs: 0x9123683E
        // XFS: 0x58465342 (with reflink enabled)
        // OCFS2: 0x7461636f
        let btrfsMagic: UInt = 0x9123683E
        let xfsMagic: UInt = 0x58465342

        let fsMagic = UInt(statfsBuf.f_type)
        if fsMagic == btrfsMagic || fsMagic == xfsMagic {
            return .reflink
        }

        return .none
    }
}
#endif

// MARK: - Windows Implementation

#if os(Windows)
extension IO.File.Clone {
    /// Attempts to duplicate file extents (ReFS block clone).
    ///
    /// This is highly constrained: same volume, ReFS only, specific alignment.
    /// Returns `false` if unsupported rather than erroring.
    package static func duplicateExtentsAttempt(
        sourceHandle: HANDLE,
        destHandle: HANDLE,
        length: UInt64
    ) throws(SyscallError) -> Bool {
        // ReFS block cloning requires FSCTL_DUPLICATE_EXTENTS_TO_FILE
        // This is complex and has many constraints, so we'll return false
        // for now and rely on CopyFile2 as the fallback.
        //
        // Full implementation would need:
        // - Verify both on same ReFS volume
        // - Align to cluster size
        // - Use DeviceIoControl with FSCTL_DUPLICATE_EXTENTS_TO_FILE
        return false
    }

    /// Copies a file using CopyFile2.
    package static func copyFile(
        source: String,
        destination: String
    ) throws(SyscallError) {
        let result = source.withCString(encodedAs: UTF16.self) { src in
            destination.withCString(encodedAs: UTF16.self) { dst in
                CopyFileW(src, dst, true) // true = fail if exists
            }
        }

        guard result != 0 else {
            throw .windows(code: GetLastError(), operation: .copy)
        }
    }

    /// Probes whether the filesystem at the given path supports cloning.
    ///
    /// On Windows, we conservatively return `.none` unless we can confirm ReFS.
    package static func probeCapability(at path: String) throws(SyscallError) -> Capability {
        // Would need GetVolumeInformationW to check for ReFS
        // For now, conservatively return .none
        return .none
    }
}
#endif

// MARK: - Common Helpers

extension IO.File.Clone {
    /// Gets the size of a file.
    #if os(macOS)
    package static func fileSize(at path: String) throws(SyscallError) -> Int {
        var statBuf = Darwin.stat()
        let result = path.withCString { p in
            stat(p, &statBuf)
        }

        guard result == 0 else {
            throw .posix(errno: errno, operation: .stat)
        }

        return Int(statBuf.st_size)
    }
    #elseif os(Linux)
    package static func fileSize(at path: String) throws(SyscallError) -> Int {
        var statBuf = Glibc.stat()
        let result = path.withCString { p in
            stat(p, &statBuf)
        }

        guard result == 0 else {
            throw .posix(errno: errno, operation: .stat)
        }

        return Int(statBuf.st_size)
    }
    #endif

    #if os(Windows)
    package static func fileSize(handle: HANDLE) throws(SyscallError) -> UInt64 {
        var size: LARGE_INTEGER = LARGE_INTEGER()
        guard GetFileSizeEx(handle, &size) != 0 else {
            throw .windows(code: GetLastError(), operation: .stat)
        }
        return UInt64(size.QuadPart)
    }
    #endif
}
