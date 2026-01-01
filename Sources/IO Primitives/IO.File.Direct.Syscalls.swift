//
//  IO.File.Direct.Syscalls.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 30/12/2025.
//
//  Platform-specific syscall wrappers for Direct I/O.
//
//  Platform notes:
//  - Linux: O_DIRECT is an open-time flag, not a runtime toggle
//  - Windows: FILE_FLAG_NO_BUFFERING is an open-time flag
//  - macOS: fcntl(F_NOCACHE) can be toggled after open
//

import Kernel
public import SystemPackage

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
import CLinuxShim
#elseif os(Windows)
import WinSDK
#endif

// MARK: - macOS Implementation

#if os(macOS)
extension IO.File.Direct {
    /// Sets or clears the F_NOCACHE flag on a file descriptor.
    ///
    /// F_NOCACHE is a *hint* that tells the kernel to avoid caching data
    /// for this file. Unlike Linux O_DIRECT, it does not impose alignment
    /// requirements and may not completely bypass the cache.
    ///
    /// - Parameters:
    ///   - descriptor: The file descriptor.
    ///   - enabled: `true` to enable no-cache, `false` to disable.
    /// - Throws: `Error.Syscall` if fcntl fails.
    package static func setNoCache(
        descriptor: IO.File.Descriptor,
        enabled: Bool
    ) throws(Error.Syscall) {
        let result = fcntl(descriptor.rawValue, F_NOCACHE, enabled ? 1 : 0)
        guard result != -1 else {
            let operation: Error.Operation = enabled ? .setNoCache : .clearNoCache
            throw .posix(errno: errno, operation: operation)
        }
    }

    /// Probes the Direct I/O capability for a path.
    ///
    /// On macOS, only `.uncached` mode (F_NOCACHE) is available.
    /// True Direct I/O with alignment requirements is not supported.
    package static func probeCapability(at path: FilePath) -> Capability {
        // macOS doesn't have true Direct I/O, only F_NOCACHE hint
        // We always return .uncachedOnly since F_NOCACHE is universally available
        return .uncachedOnly
    }

    /// Gets alignment requirements for a file descriptor.
    ///
    /// On macOS, there are no alignment requirements since F_NOCACHE
    /// is a hint, not a strict bypass. Returns `.unknown(.platformUnsupported)`.
    package static func getRequirements(
        descriptor: Int32
    ) throws(Error.Syscall) -> Requirements {
        // macOS F_NOCACHE has no alignment requirements
        return .unknown(reason: .platformUnsupported)
    }
}
#endif

// MARK: - Linux Implementation

#if os(Linux)
extension IO.File.Direct {
    /// The O_DIRECT open flag value.
    ///
    /// This is the flag to pass when opening a file for Direct I/O.
    /// Note: O_DIRECT must be set at open time, not after.
    package static var openDirectFlag: Int32 {
        O_DIRECT
    }

    /// Probes the Direct I/O capability for a path.
    ///
    /// On Linux, Direct I/O is filesystem-dependent but widely supported.
    /// The main exceptions are network filesystems and some FUSE implementations.
    package static func probeCapability(at path: FilePath) -> Capability {
        // Get filesystem type via statfs
        var statfsBuf = CLinuxShim.statfs()
        let result = path.withPlatformString { p in
            CLinuxShim.swift_statfs(p, &statfsBuf)
        }

        guard result == 0 else {
            return .bufferedOnly
        }

        // Known filesystems that DON'T support O_DIRECT well
        // NFS: 0x6969
        // CIFS: 0xFF534D42
        // tmpfs: 0x01021994
        let nfsMagic: UInt = 0x6969
        let cifsMagic: UInt = 0xFF534D42
        let tmpfsMagic: UInt = 0x01021994

        let fsMagic = UInt(statfsBuf.f_type)
        if fsMagic == nfsMagic || fsMagic == cifsMagic || fsMagic == tmpfsMagic {
            return .bufferedOnly
        }

        // For supported filesystems, check requirements
        let requirements = Requirements(path)
        if case .known(let alignment) = requirements {
            return .directSupported(alignment)
        }
        return .bufferedOnly
    }

    /// Gets alignment requirements for a file descriptor.
    ///
    /// **Important:** Linux O_DIRECT alignment constraints are not reliably
    /// derivable from `statfs` or other standard APIs. They vary by filesystem,
    /// device, and configuration, and are often only enforced at syscall time
    /// via `EINVAL`.
    ///
    /// This implementation returns `.unknown` to fail closed. Callers who need
    /// Direct I/O should either:
    /// 1. Use `.auto(.fallbackToBuffered)` for best-effort operation
    /// 2. Provide explicit alignment via `IO.File.open` with custom requirements
    /// 3. Handle `EINVAL` errors as potential alignment violations
    ///
    /// For reference, common safe alignments are:
    /// - 512 bytes: Legacy HDDs, some older filesystems
    /// - 4096 bytes: Modern SSDs, NVMe, most ext4/XFS configurations
    /// - Page size: Conservative fallback (typically 4096)
    package static func getRequirements(
        descriptor: Int32
    ) throws(Error.Syscall) -> Requirements {
        // Linux O_DIRECT alignment is not reliably discoverable.
        // statfs.f_bsize is the optimal transfer size, NOT the alignment requirement.
        // Actual requirements depend on device sector size, filesystem, and driver.
        //
        // Fail closed: return unknown rather than guess wrong.
        return .unknown(reason: .sectorSizeUndetermined)
    }
}
#endif

// MARK: - Windows Implementation

#if os(Windows)
extension IO.File.Direct {
    /// The FILE_FLAG_NO_BUFFERING open flag value.
    ///
    /// This is the flag to pass when opening a file for Direct I/O.
    /// Note: Must be set at CreateFile time, not after.
    package static var openDirectFlag: DWORD {
        DWORD(FILE_FLAG_NO_BUFFERING)
    }

    /// Probes the Direct I/O capability for a path.
    ///
    /// On Windows, NO_BUFFERING is widely supported but requires knowing
    /// the sector size for alignment. If we can't determine sector size,
    /// we report buffered-only.
    package static func probeCapability(at path: FilePath) -> Capability {
        let requirements = Requirements(path)
        if case .known(let alignment) = requirements {
            return .directSupported(alignment)
        }
        return .bufferedOnly
    }

    /// Gets alignment requirements for a file handle.
    ///
    /// This is more complex on Windows as we need to get the file path
    /// from the handle first. For simplicity, we require the path to be
    /// provided at open time.
    package static func getRequirements(
        handle: HANDLE
    ) throws(Error.Syscall) -> Requirements {
        guard handle != INVALID_HANDLE_VALUE else {
            throw .invalidDescriptor(operation: .getSectorSize)
        }

        // Getting path from handle requires GetFinalPathNameByHandle
        // which adds complexity. For now, return a conservative default.
        //
        // Most modern Windows storage uses 512 or 4096 byte sectors.
        // We'll use 4096 as a safe default, but callers should prefer
        // querying with a path when possible.
        return .known(Requirements.Alignment(uniform: 4096))
    }
}
#endif

// MARK: - Common Helpers

// Page size: Use `Kernel.System.pageSize` from swift-kernel
