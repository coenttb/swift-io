//
//  IO.Memory.Map.Syscalls.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 30/12/2025.
//
//  Package-internal syscall wrappers for memory mapping.
//  Platform imports are quarantined to this file.
//

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#elseif os(Windows)
    import WinSDK
#endif

// MARK: - Protection Flags

extension IO.Memory.Map {
    /// Memory protection flags for mapped regions.
    package struct Protection: OptionSet, Sendable {
        package let rawValue: Int32

        package init(rawValue: Int32) {
            self.rawValue = rawValue
        }

        /// Pages may be read.
        package static let read = Protection(rawValue: 1 << 0)

        /// Pages may be written.
        package static let write = Protection(rawValue: 1 << 1)

        /// Pages may be executed.
        package static let execute = Protection(rawValue: 1 << 2)

        /// No access permitted.
        package static let none: Protection = []

        /// Read and write access.
        package static let readWrite: Protection = [.read, .write]

        #if !os(Windows)
        /// Converts to POSIX protection flags (PROT_READ, PROT_WRITE, PROT_EXEC).
        var posix: Int32 {
            var flags: Int32 = 0
            if contains(.read) { flags |= PROT_READ }
            if contains(.write) { flags |= PROT_WRITE }
            if contains(.execute) { flags |= PROT_EXEC }
            return flags
        }
        #endif

        #if os(Windows)
        /// Converts to Windows page protection constant.
        ///
        /// Windows protection is not a simple bitmask - it uses combined constants.
        var windowsPageProtection: DWORD {
            switch (contains(.read), contains(.write), contains(.execute)) {
            case (false, false, false): return DWORD(PAGE_NOACCESS)
            case (true, false, false): return DWORD(PAGE_READONLY)
            case (true, true, false): return DWORD(PAGE_READWRITE)
            case (true, false, true): return DWORD(PAGE_EXECUTE_READ)
            case (true, true, true): return DWORD(PAGE_EXECUTE_READWRITE)
            case (false, false, true): return DWORD(PAGE_EXECUTE)
            case (false, true, false): return DWORD(PAGE_READWRITE) // Write implies read on Windows
            case (false, true, true): return DWORD(PAGE_EXECUTE_READWRITE)
            }
        }

        /// Converts to Windows file mapping access flags.
        var windowsFileMapAccess: DWORD {
            var access: DWORD = 0
            if contains(.read) { access |= DWORD(FILE_MAP_READ) }
            if contains(.write) { access |= DWORD(FILE_MAP_WRITE) }
            if contains(.execute) { access |= DWORD(FILE_MAP_EXECUTE) }
            return access
        }
        #endif
    }
}

// MARK: - Sharing Flags

extension IO.Memory.Map {
    /// Sharing semantics for mapped regions.
    package enum Sharing: Sendable {
        /// Changes are shared with other mappings (MAP_SHARED / normal file mapping).
        case shared

        /// Changes are private (copy-on-write) (MAP_PRIVATE / PAGE_WRITECOPY).
        case `private`

        #if !os(Windows)
        /// Converts to POSIX map flags.
        var posixMapFlags: Int32 {
            switch self {
            case .shared: return MAP_SHARED
            case .private: return MAP_PRIVATE
            }
        }
        #endif

        #if os(Windows)
        /// Adjusts Windows page protection for copy-on-write.
        func adjustWindowsProtection(_ protection: DWORD) -> DWORD {
            switch self {
            case .shared:
                return protection
            case .private:
                // Convert to copy-on-write variants
                switch Int32(protection) {
                case PAGE_READWRITE: return DWORD(PAGE_WRITECOPY)
                case PAGE_EXECUTE_READWRITE: return DWORD(PAGE_EXECUTE_WRITECOPY)
                default: return protection
                }
            }
        }

        /// Returns the file map access for copy-on-write.
        var windowsFileMapCopy: Bool {
            self == .private
        }
        #endif
    }
}

// MARK: - Mapping Result

extension IO.Memory.Map {
    /// Result of a memory mapping operation.
    package struct Mapping: @unchecked Sendable {
        /// The base address of the mapped region.
        package let baseAddress: UnsafeMutableRawPointer

        /// The actual mapped length (may be larger than requested due to alignment).
        package let mappedLength: Int

        #if os(Windows)
        /// Windows file mapping handle (must be closed separately).
        package let mappingHandle: HANDLE?
        #endif

        #if os(Windows)
        package init(
            baseAddress: UnsafeMutableRawPointer,
            mappedLength: Int,
            mappingHandle: HANDLE?
        ) {
            self.baseAddress = baseAddress
            self.mappedLength = mappedLength
            self.mappingHandle = mappingHandle
        }
        #else
        package init(baseAddress: UnsafeMutableRawPointer, mappedLength: Int) {
            self.baseAddress = baseAddress
            self.mappedLength = mappedLength
        }
        #endif
    }
}

// MARK: - Advice

extension IO.Memory.Map {
    /// Memory access advice for madvise.
    public enum Advice: Sendable {
        /// Normal access pattern.
        case normal
        /// Sequential access expected.
        case sequential
        /// Random access expected.
        case random
        /// Will need this data soon.
        case willNeed
        /// Will not need this data soon.
        case dontNeed

        #if !os(Windows)
        var posix: Int32 {
            switch self {
            case .normal: return MADV_NORMAL
            case .sequential: return MADV_SEQUENTIAL
            case .random: return MADV_RANDOM
            case .willNeed: return MADV_WILLNEED
            case .dontNeed: return MADV_DONTNEED
            }
        }
        #endif
    }
}

// MARK: - POSIX Implementation

#if !os(Windows)
extension IO.Memory.Map {
    /// Maps a file into memory using POSIX mmap.
    ///
    /// - Parameters:
    ///   - fileDescriptor: The file descriptor to map.
    ///   - offset: Offset into the file (must be page-aligned).
    ///   - length: Number of bytes to map.
    ///   - protection: Memory protection flags.
    ///   - sharing: Sharing semantics.
    /// - Returns: The mapping result containing base address and length.
    /// - Throws: `Error.Syscall` if mmap fails.
    package static func mapFile(
        descriptor: Int32,
        offset: Int,
        length: Int,
        protection: Protection,
        sharing: Sharing
    ) throws(Error.Syscall) -> Mapping {
        guard length > 0 else {
            throw .invalidLength(operation: .map)
        }

        let flags = sharing.posixMapFlags
        let prot = protection.posix

        let result = mmap(
            nil,
            length,
            prot,
            flags,
            descriptor,
            off_t(offset)
        )

        guard result != MAP_FAILED else {
            throw .posix(errno: errno, operation: .map)
        }

        return Mapping(
            baseAddress: result!,
            mappedLength: length
        )
    }

    /// Maps anonymous memory (not backed by a file).
    ///
    /// - Parameters:
    ///   - length: Number of bytes to map.
    ///   - protection: Memory protection flags.
    ///   - sharing: Sharing semantics.
    /// - Returns: The mapping result.
    /// - Throws: `Error.Syscall` if mmap fails.
    package static func mapAnonymous(
        length: Int,
        protection: Protection,
        sharing: Sharing
    ) throws(Error.Syscall) -> Mapping {
        guard length > 0 else {
            throw .invalidLength(operation: .map)
        }

        let flags = sharing.posixMapFlags | MAP_ANON
        let prot = protection.posix

        let result = mmap(
            nil,
            length,
            prot,
            flags,
            -1,
            0
        )

        guard result != MAP_FAILED else {
            throw .posix(errno: errno, operation: .map)
        }

        return Mapping(
            baseAddress: result!,
            mappedLength: length
        )
    }

    /// Unmaps a previously mapped region.
    ///
    /// - Parameters:
    ///   - address: The base address of the mapping.
    ///   - length: The length of the mapping.
    /// - Throws: `Error.Syscall` if munmap fails.
    package static func unmap(
        address: UnsafeMutableRawPointer,
        length: Int
    ) throws(Error.Syscall) {
        let result = munmap(address, length)
        guard result == 0 else {
            throw .posix(errno: errno, operation: .unmap)
        }
    }

    /// Synchronizes a mapped region to disk.
    ///
    /// - Parameters:
    ///   - address: The base address of the region to sync.
    ///   - length: The length of the region.
    ///   - async: If true, returns immediately and syncs asynchronously.
    /// - Throws: `Error.Syscall` if msync fails.
    package static func sync(
        address: UnsafeMutableRawPointer,
        length: Int,
        async: Bool = false
    ) throws(Error.Syscall) {
        let flags = async ? MS_ASYNC : MS_SYNC
        let result = msync(address, length, flags)
        guard result == 0 else {
            throw .posix(errno: errno, operation: .sync)
        }
    }

    /// Changes the protection on a mapped region.
    ///
    /// - Parameters:
    ///   - address: The base address (must be page-aligned).
    ///   - length: The length of the region.
    ///   - protection: The new protection flags.
    /// - Throws: `Error.Syscall` if mprotect fails.
    package static func protect(
        address: UnsafeMutableRawPointer,
        length: Int,
        protection: Protection
    ) throws(Error.Syscall) {
        let result = mprotect(address, length, protection.posix)
        guard result == 0 else {
            throw .posix(errno: errno, operation: .protect)
        }
    }

    /// Advises the kernel about expected access patterns.
    ///
    /// - Parameters:
    ///   - address: The base address.
    ///   - length: The length of the region.
    ///   - advice: The advice type.
    package static func advise(
        address: UnsafeMutableRawPointer,
        length: Int,
        advice: Advice
    ) {
        // madvise is advisory - we ignore failures
        _ = madvise(address, length, advice.posix)
    }
}
#endif

// MARK: - Windows Implementation

#if os(Windows)
extension IO.Memory.Map {
    /// Maps a file into memory using Windows APIs.
    ///
    /// - Parameters:
    ///   - fileHandle: The file handle to map.
    ///   - offset: Offset into the file (must be allocation-granularity aligned).
    ///   - length: Number of bytes to map.
    ///   - protection: Memory protection flags.
    ///   - sharing: Sharing semantics.
    /// - Returns: The mapping result containing base address, length, and mapping handle.
    /// - Throws: `Error.Syscall` if mapping fails.
    package static func mapFile(
        handle fileHandle: HANDLE,
        offset: Int,
        length: Int,
        protection: Protection,
        sharing: Sharing
    ) throws(Error.Syscall) -> Mapping {
        guard length > 0 else {
            throw .invalidLength(operation: .map)
        }

        guard fileHandle != INVALID_HANDLE_VALUE else {
            throw .invalidHandle(operation: .map)
        }

        // Create file mapping object
        let pageProtection = sharing.adjustWindowsProtection(protection.windowsPageProtection)
        let maxSizeHigh = DWORD((UInt64(offset) + UInt64(length)) >> 32)
        let maxSizeLow = DWORD((UInt64(offset) + UInt64(length)) & 0xFFFFFFFF)

        let mappingHandle = CreateFileMappingW(
            fileHandle,
            nil,
            pageProtection,
            maxSizeHigh,
            maxSizeLow,
            nil
        )

        guard mappingHandle != nil else {
            throw .windows(code: GetLastError(), operation: .map)
        }

        // Map view of file
        var access = protection.windowsFileMapAccess
        if sharing.windowsFileMapCopy {
            access = DWORD(FILE_MAP_COPY)
        }

        let offsetHigh = DWORD(UInt64(offset) >> 32)
        let offsetLow = DWORD(UInt64(offset) & 0xFFFFFFFF)

        let viewAddress = MapViewOfFile(
            mappingHandle,
            access,
            offsetHigh,
            offsetLow,
            SIZE_T(length)
        )

        guard let address = viewAddress else {
            CloseHandle(mappingHandle)
            throw .windows(code: GetLastError(), operation: .map)
        }

        return Mapping(
            baseAddress: address,
            mappedLength: length,
            mappingHandle: mappingHandle
        )
    }

    /// Maps anonymous memory (pagefile-backed).
    ///
    /// - Parameters:
    ///   - length: Number of bytes to map.
    ///   - protection: Memory protection flags.
    ///   - sharing: Sharing semantics.
    /// - Returns: The mapping result.
    /// - Throws: `Error.Syscall` if mapping fails.
    package static func mapAnonymous(
        length: Int,
        protection: Protection,
        sharing: Sharing
    ) throws(Error.Syscall) -> Mapping {
        guard length > 0 else {
            throw .invalidLength(operation: .map)
        }

        // Use INVALID_HANDLE_VALUE for pagefile-backed mapping
        let pageProtection = sharing.adjustWindowsProtection(protection.windowsPageProtection)
        let maxSizeHigh = DWORD(UInt64(length) >> 32)
        let maxSizeLow = DWORD(UInt64(length) & 0xFFFFFFFF)

        let mappingHandle = CreateFileMappingW(
            INVALID_HANDLE_VALUE,
            nil,
            pageProtection,
            maxSizeHigh,
            maxSizeLow,
            nil
        )

        guard mappingHandle != nil else {
            throw .windows(code: GetLastError(), operation: .map)
        }

        var access = protection.windowsFileMapAccess
        if sharing.windowsFileMapCopy {
            access = DWORD(FILE_MAP_COPY)
        }

        let viewAddress = MapViewOfFile(
            mappingHandle,
            access,
            0,
            0,
            SIZE_T(length)
        )

        guard let address = viewAddress else {
            CloseHandle(mappingHandle)
            throw .windows(code: GetLastError(), operation: .map)
        }

        return Mapping(
            baseAddress: address,
            mappedLength: length,
            mappingHandle: mappingHandle
        )
    }

    /// Unmaps a previously mapped view.
    ///
    /// - Parameters:
    ///   - address: The base address of the view.
    ///   - mappingHandle: The file mapping handle to close.
    /// - Throws: `Error.Syscall` if unmapping fails.
    package static func unmap(
        address: UnsafeMutableRawPointer,
        mappingHandle: HANDLE?
    ) throws(Error.Syscall) {
        let unmapResult = UnmapViewOfFile(address)

        if let handle = mappingHandle {
            CloseHandle(handle)
        }

        guard unmapResult != 0 else {
            throw .windows(code: GetLastError(), operation: .unmap)
        }
    }

    /// Flushes a mapped view to disk.
    ///
    /// - Parameters:
    ///   - address: The base address of the region to flush.
    ///   - length: The length of the region.
    /// - Throws: `Error.Syscall` if flushing fails.
    package static func sync(
        address: UnsafeMutableRawPointer,
        length: Int
    ) throws(Error.Syscall) {
        let result = FlushViewOfFile(address, SIZE_T(length))
        guard result != 0 else {
            throw .windows(code: GetLastError(), operation: .sync)
        }
    }

    /// Changes the protection on a mapped region.
    ///
    /// - Parameters:
    ///   - address: The base address.
    ///   - length: The length of the region.
    ///   - protection: The new protection flags.
    /// - Throws: `Error.Syscall` if protection change fails.
    package static func protect(
        address: UnsafeMutableRawPointer,
        length: Int,
        protection: Protection
    ) throws(Error.Syscall) {
        var oldProtection: DWORD = 0
        let result = VirtualProtect(
            address,
            SIZE_T(length),
            protection.windowsPageProtection,
            &oldProtection
        )
        guard result != 0 else {
            throw .windows(code: GetLastError(), operation: .protect)
        }
    }

    /// Advises the system about expected access patterns.
    ///
    /// Windows has limited madvise-equivalent functionality.
    /// For now, this is a no-op.
    package static func advise(
        address: UnsafeMutableRawPointer,
        length: Int,
        advice: Advice
    ) {
        // Windows doesn't have direct madvise equivalent
        // PrefetchVirtualMemory could be used for willNeed but requires
        // Windows 8+ and more complex setup - left for future optimization
    }
}
#endif
