//
//  IO.Memory.Map.Region.swift
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
    /// A move-only memory-mapped file region.
    ///
    /// `Region` provides safe access to memory-mapped files with:
    /// - Fixed-length semantics (no auto-grow)
    /// - Platform-abstracted offset alignment
    /// - Optional lock-based SIGBUS safety
    ///
    /// ## Lifetime
    /// - `Region` is `~Copyable` (move-only)
    /// - Use `unmap()` to explicitly release the mapping
    /// - `deinit` releases the mapping as a backstop
    ///
    /// ## Safety Modes
    /// - `.coordinated`: Holds a file lock for the mapping lifetime (prevents SIGBUS from truncation)
    /// - `.unchecked`: No lock held; caller accepts crash risk from concurrent truncation
    ///
    /// ## Thread Safety
    ///
    /// `Region` is `@unchecked Sendable` because:
    /// - The underlying memory mapping is a raw pointer to shared memory
    /// - The compiler cannot verify thread-safe access patterns
    /// - Callers must ensure appropriate synchronization when accessing
    ///   the mapped memory from multiple threads/tasks
    ///
    /// For `.coordinated` safety mode, the held file lock provides protection
    /// against external truncation, but does **not** synchronize concurrent
    /// in-process access to the mapped bytes.
    ///
    /// ## Example
    /// ```swift
    /// let region = try IO.Memory.Map.Region(
    ///     fileDescriptor: fd,
    ///     range: .bytes(offset: 0, length: 4096),
    ///     access: .read,
    ///     sharing: .shared,
    ///     safety: .unchecked
    /// )
    /// defer { region.unmap() }
    ///
    /// let byte = region[0]
    /// ```
    public struct Region: ~Copyable, @unchecked Sendable {
        // MARK: - Internal State

        /// The base address of the actual OS mapping (granularity-aligned).
        private var mappingBaseAddress: UnsafeMutableRawPointer?

        /// The length of the actual OS mapping.
        private let mappingLength: Int

        /// Delta between user-requested offset and mapping base.
        private let offsetDelta: Int

        /// The user-visible length (requested length).
        private let userLength: Int

        /// The access mode for this mapping.
        public let access: Access

        /// The sharing mode for this mapping.
        public let sharing: Sharing

        /// The safety mode for this mapping.
        public let safety: Safety

        #if os(Windows)
        /// Windows file mapping handle (must be closed on unmap).
        private var mappingHandle: HANDLE?
        #endif

        /// Lock token for `.coordinated` safety mode.
        /// Holds a file lock for the mapping lifetime to prevent SIGBUS from truncation.
        private var lockToken: LockToken?

        // MARK: - Computed Properties

        /// The base address for user access (adjusted for offset delta).
        public var baseAddress: UnsafeRawPointer? {
            guard let base = mappingBaseAddress else { return nil }
            return UnsafeRawPointer(base.advanced(by: offsetDelta))
        }

        /// Mutable base address (only valid if access includes write).
        public var mutableBaseAddress: UnsafeMutableRawPointer? {
            guard access.allowsWrite, let base = mappingBaseAddress else { return nil }
            return base.advanced(by: offsetDelta)
        }

        /// The length of the mapped region visible to the user.
        public var length: Int { userLength }

        /// Whether the mapping is still valid.
        public var isMapped: Bool { mappingBaseAddress != nil }

        // MARK: - deinit

        deinit {
            // Backstop release - correctness should not depend on this
            guard let base = mappingBaseAddress else { return }

            lockToken?.release()

            #if os(Windows)
            try? IO.Memory.Map.unmap(address: base, mappingHandle: mappingHandle)
            #else
            try? IO.Memory.Map.unmap(address: base, length: mappingLength)
            #endif
        }
    }
}

// MARK: - Access Mode

extension IO.Memory.Map.Region {
    /// Access mode for the mapped region.
    public enum Access: Sendable, Equatable {
        /// Read-only access.
        case read

        /// Read and write access.
        case readWrite

        /// Copy-on-write access (writes are private to this mapping).
        case copyOnWrite

        // Note: .execute is intentionally not included in v1
        // due to portability and security policy concerns

        /// Whether this access mode allows reading.
        public var allowsRead: Bool { true }

        /// Whether this access mode allows writing.
        public var allowsWrite: Bool {
            switch self {
            case .read: return false
            case .readWrite, .copyOnWrite: return true
            }
        }

        /// Converts to platform protection flags.
        var platformProtection: IO.Memory.Map.Protection {
            switch self {
            case .read: return .read
            case .readWrite, .copyOnWrite: return .readWrite
            }
        }
    }
}

// MARK: - Sharing Mode

extension IO.Memory.Map.Region {
    /// Sharing semantics for the mapped region.
    public enum Sharing: Sendable, Equatable {
        /// Changes are visible to other mappings of the same file.
        ///
        /// Maps to:
        /// - POSIX: `MAP_SHARED`
        /// - Windows: Normal file mapping with `PAGE_READWRITE`
        case shared

        /// Changes are private to this mapping (copy-on-write).
        ///
        /// Maps to:
        /// - POSIX: `MAP_PRIVATE`
        /// - Windows: `PAGE_WRITECOPY` with `FILE_MAP_COPY`
        case `private`

        /// Converts to platform sharing mode.
        var platformSharing: IO.Memory.Map.Sharing {
            switch self {
            case .shared: return .shared
            case .private: return .private
            }
        }
    }
}

// MARK: - Range

extension IO.Memory.Map.Region {
    /// Range specification for mapping.
    public enum Range: Sendable, Equatable {
        /// Map a specific byte range.
        ///
        /// - Parameters:
        ///   - offset: Starting offset in the file (will be aligned down to granularity).
        ///   - length: Number of bytes to map.
        case bytes(offset: Int, length: Int)

        /// Map the whole file.
        ///
        /// The file size is queried at map time via `fstat` (POSIX) or
        /// `GetFileSizeEx` (Windows). This provides a **snapshot** of the size
        /// at the moment of mapping.
        ///
        /// - Important: This is not a live view. If the file grows after mapping,
        ///   the region does **not** automatically extend. Use `remap()` to create
        ///   a new mapping with the updated size.
        case wholeFile

        /// The starting offset.
        public var offset: Int {
            switch self {
            case .bytes(let offset, _): return offset
            case .wholeFile: return 0
            }
        }

        /// The length for a specific byte range.
        ///
        /// - Note: For `.wholeFile`, returns 0. The actual length is resolved
        ///         at map time by querying the file.
        public var length: Int? {
            switch self {
            case .bytes(_, let length): return length
            case .wholeFile: return nil
            }
        }
    }
}

// MARK: - Safety Mode

extension IO.Memory.Map.Region {
    /// Safety mode for SIGBUS/access-violation protection.
    public enum Safety: Sendable, Equatable {
        /// Coordinated access with file locking.
        ///
        /// The mapping holds a file lock for its entire lifetime.
        /// This prevents SIGBUS from truncation **if all writers respect the same lock discipline**.
        ///
        /// - Parameters:
        ///   - mode: The lock mode (.shared for read, .exclusive for write).
        ///   - scope: The lock scope (.wholeFile or .mappedRange).
        case coordinated(LockMode, scope: LockScope)

        /// Unchecked access with no locking.
        ///
        /// The caller accepts the risk of SIGBUS/access-violation if the file
        /// is truncated or modified by another process.
        ///
        /// Use for: append-only files, immutable snapshots, WAL segments.
        case unchecked

        /// Lock mode for coordinated safety.
        public enum LockMode: Sendable, Equatable {
            /// Shared lock (allows concurrent readers).
            case shared
            /// Exclusive lock (no concurrent access).
            case exclusive
        }

        /// Lock scope for coordinated safety.
        public enum LockScope: Sendable, Equatable {
            /// Lock the entire file (0..<UInt64.max).
            case wholeFile
            /// Lock the mapped range (rounded to granularity).
            case mappedRange
        }

        /// Default safety for read access.
        public static var defaultForRead: Safety {
            .coordinated(.shared, scope: .mappedRange)
        }

        /// Default safety for write access.
        public static var defaultForWrite: Safety {
            .coordinated(.exclusive, scope: .mappedRange)
        }
    }
}

// MARK: - Lock Token Wrapper

extension IO.Memory.Map.Region {
    /// Wrapper that holds a file lock for the Region's lifetime.
    ///
    /// This is a class because `IO.File.Lock.Token` is ~Copyable and cannot
    /// be stored directly in an optional field. The class provides indirection.
    final class LockToken: @unchecked Sendable {
        #if os(Windows)
        private var token: IO.File.Lock.Token?

        init(handle: HANDLE, range: IO.File.Lock.Range, mode: IO.File.Lock.Mode) throws {
            self.token = try IO.File.Lock.Token(handle: handle, range: range, mode: mode)
        }
        #else
        private var token: IO.File.Lock.Token?

        init(descriptor: Int32, range: IO.File.Lock.Range, mode: IO.File.Lock.Mode) throws {
            self.token = try IO.File.Lock.Token(descriptor: descriptor, range: range, mode: mode)
        }
        #endif

        func release() {
            // Setting to nil drops the token, triggering its deinit which releases the lock
            token = nil
        }

        deinit {
            // Token's deinit will release the lock if still held
            // No explicit action needed here - just let the token be destroyed
        }
    }
}

// MARK: - Initialization (File-backed)

extension IO.Memory.Map.Region {
    /// Creates a memory-mapped region from a file descriptor.
    ///
    /// - Parameters:
    ///   - fileDescriptor: The POSIX file descriptor to map.
    ///   - range: The range to map (offset will be aligned to allocation granularity).
    ///   - access: The access mode.
    ///   - sharing: The sharing mode.
    ///   - safety: The safety mode (defaults based on access).
    /// - Throws: `IO.Memory.Map.Error` if mapping fails.
    #if !os(Windows)
    public init(
        fileDescriptor: Int32,
        range: Range,
        access: Access = .read,
        sharing: Sharing = .shared,
        safety: Safety? = nil
    ) throws(IO.Memory.Map.Error) {
        let effectiveSafety = safety ?? (access.allowsWrite ? .defaultForWrite : .defaultForRead)

        // Resolve range length (query file size for .wholeFile)
        let userLen: Int
        switch range {
        case .bytes(_, let length):
            userLen = length
        case .wholeFile:
            var statBuf = stat()
            guard fstat(fileDescriptor, &statBuf) == 0 else {
                throw .platform(code: errno, message: "fstat failed: \(String(cString: strerror(errno)))")
            }
            userLen = Int(statBuf.st_size)
            guard userLen > 0 else {
                throw .fileTooSmall
            }
        }

        // Calculate alignment
        let requestedOffset = range.offset
        let alignedOffset = IO.Memory.alignOffsetDown(requestedOffset)
        let delta = requestedOffset - alignedOffset
        let mappingLen = IO.Memory.alignLengthUp(userLen + delta)

        // Adjust sharing for copyOnWrite access
        let effectiveSharing: Sharing = (access == .copyOnWrite) ? .private : sharing

        // Perform all throwing work before initializing any stored properties
        // (required for ~Copyable types)

        // 1. Map the file
        let result: IO.Memory.Map.Mapping
        do {
            result = try IO.Memory.Map.mapFile(
                descriptor: fileDescriptor,
                offset: alignedOffset,
                length: mappingLen,
                protection: access.platformProtection,
                sharing: effectiveSharing.platformSharing
            )
        } catch {
            throw IO.Memory.Map.Error(from: error)
        }

        // 2. Acquire lock if needed
        let acquiredLockToken: LockToken?
        if case .coordinated(let mode, let scope) = effectiveSafety {
            let lockRange = Self.computeLockRange(scope: scope, alignedOffset: alignedOffset, mappingLength: mappingLen)
            let lockMode: IO.File.Lock.Mode = (mode == .shared) ? .shared : .exclusive
            do {
                acquiredLockToken = try LockToken(descriptor: fileDescriptor, range: lockRange, mode: lockMode)
            } catch let lockError as IO.File.Lock.Error {
                // Unmap on lock failure (before we've initialized self)
                try? IO.Memory.Map.unmap(address: result.baseAddress, length: mappingLen)
                throw .lockAcquisitionFailed(lockError)
            } catch {
                // Unexpected error type - shouldn't happen but handle gracefully
                try? IO.Memory.Map.unmap(address: result.baseAddress, length: mappingLen)
                throw .platform(code: 0, message: "Unexpected lock error: \(error)")
            }
        } else {
            acquiredLockToken = nil
        }

        // Now initialize all stored properties at once
        self.mappingBaseAddress = result.baseAddress
        self.mappingLength = result.mappedLength
        self.offsetDelta = delta
        self.userLength = userLen
        self.access = access
        self.sharing = effectiveSharing
        self.safety = effectiveSafety
        self.lockToken = acquiredLockToken
    }
    #endif

    #if os(Windows)
    /// Creates a memory-mapped region from a Windows file handle.
    ///
    /// - Parameters:
    ///   - fileHandle: The Windows file handle to map.
    ///   - range: The range to map (offset will be aligned to allocation granularity).
    ///   - access: The access mode.
    ///   - sharing: The sharing mode.
    ///   - safety: The safety mode (defaults based on access).
    /// - Throws: `IO.Memory.Map.Error` if mapping fails.
    public init(
        fileHandle: HANDLE,
        range: Range,
        access: Access = .read,
        sharing: Sharing = .shared,
        safety: Safety? = nil
    ) throws(IO.Memory.Map.Error) {
        let effectiveSafety = safety ?? (access.allowsWrite ? .defaultForWrite : .defaultForRead)

        // Resolve range length (query file size for .wholeFile)
        let userLen: Int
        switch range {
        case .bytes(_, let length):
            userLen = length
        case .wholeFile:
            var fileSize: LARGE_INTEGER = LARGE_INTEGER()
            guard GetFileSizeEx(fileHandle, &fileSize) != 0 else {
                throw .platform(code: Int32(GetLastError()), message: "GetFileSizeEx failed")
            }
            userLen = Int(fileSize.QuadPart)
            guard userLen > 0 else {
                throw .fileTooSmall
            }
        }

        // Calculate alignment (Windows uses 64KB granularity)
        let requestedOffset = range.offset
        let alignedOffset = IO.Memory.alignOffsetDown(requestedOffset)
        let delta = requestedOffset - alignedOffset
        let mappingLen = IO.Memory.alignLengthUp(userLen + delta)

        // Adjust sharing for copyOnWrite access
        let effectiveSharing: Sharing = (access == .copyOnWrite) ? .private : sharing

        // Perform all throwing work before initializing any stored properties
        // (required for ~Copyable types)

        // 1. Map the file
        let result: IO.Memory.Map.Mapping
        do {
            result = try IO.Memory.Map.mapFile(
                handle: fileHandle,
                offset: alignedOffset,
                length: mappingLen,
                protection: access.platformProtection,
                sharing: effectiveSharing.platformSharing
            )
        } catch {
            throw IO.Memory.Map.Error(from: error)
        }

        // 2. Acquire lock if needed
        let acquiredLockToken: LockToken?
        if case .coordinated(let mode, let scope) = effectiveSafety {
            let lockRange = Self.computeLockRange(scope: scope, alignedOffset: alignedOffset, mappingLength: mappingLen)
            let lockMode: IO.File.Lock.Mode = (mode == .shared) ? .shared : .exclusive
            do {
                acquiredLockToken = try LockToken(handle: fileHandle, range: lockRange, mode: lockMode)
            } catch let lockError as IO.File.Lock.Error {
                // Unmap on lock failure (before we've initialized self)
                try? IO.Memory.Map.unmap(address: result.baseAddress, mappingHandle: result.mappingHandle)
                throw .lockAcquisitionFailed(lockError)
            } catch {
                // Unexpected error type - shouldn't happen but handle gracefully
                try? IO.Memory.Map.unmap(address: result.baseAddress, mappingHandle: result.mappingHandle)
                throw .platform(code: 0, message: "Unexpected lock error: \(error)")
            }
        } else {
            acquiredLockToken = nil
        }

        // Now initialize all stored properties at once
        self.mappingBaseAddress = result.baseAddress
        self.mappingLength = result.mappedLength
        self.offsetDelta = delta
        self.userLength = userLen
        self.access = access
        self.sharing = effectiveSharing
        self.safety = effectiveSafety
        self.mappingHandle = result.mappingHandle
        self.lockToken = acquiredLockToken
    }
    #endif

    /// Computes the lock range based on scope.
    ///
    /// For `.mappedRange`, the lock range is rounded to the platform's mapping granularity:
    /// - POSIX: page size
    /// - Windows: allocation granularity (64KB typically)
    ///
    /// This ensures the lock covers exactly the memory region that could be faulted.
    ///
    /// - Note: Rounding may lock bytes beyond the logical user-requested range.
    ///   This is intentional: the lock must cover every byte that the OS mapping
    ///   could fault on, which includes the padding bytes up to the next granularity
    ///   boundary.
    private static func computeLockRange(scope: Safety.LockScope, alignedOffset: Int, mappingLength: Int) -> IO.File.Lock.Range {
        switch scope {
        case .wholeFile:
            return .wholeFile
        case .mappedRange:
            // Round the end up to granularity to match the mapping's actual coverage
            let granularity = IO.Memory.granularity
            let end = alignedOffset + mappingLength
            let roundedEnd = (end + granularity - 1) / granularity * granularity
            return IO.File.Lock.Range(start: UInt64(alignedOffset), end: UInt64(roundedEnd))
        }
    }
}

// MARK: - Initialization (Anonymous)

extension IO.Memory.Map.Region {
    /// Creates an anonymous memory mapping (not backed by a file).
    ///
    /// Anonymous mappings are backed by:
    /// - POSIX: Swap/memory only
    /// - Windows: The system pagefile
    ///
    /// - Parameters:
    ///   - length: The number of bytes to map.
    ///   - access: The access mode (default: readWrite).
    ///   - sharing: The sharing mode (default: private).
    /// - Throws: `IO.Memory.Map.Error` if mapping fails.
    public init(
        anonymousLength length: Int,
        access: Access = .readWrite,
        sharing: Sharing = .private
    ) throws(IO.Memory.Map.Error) {
        let mappingLen = IO.Memory.alignLengthUp(length)

        let result: IO.Memory.Map.Mapping
        do {
            result = try IO.Memory.Map.mapAnonymous(
                length: mappingLen,
                protection: access.platformProtection,
                sharing: sharing.platformSharing
            )
        } catch {
            throw IO.Memory.Map.Error(from: error)
        }

        self.mappingBaseAddress = result.baseAddress
        self.mappingLength = result.mappedLength
        self.offsetDelta = 0
        self.userLength = length
        self.access = access
        self.sharing = sharing
        self.safety = .unchecked  // Anonymous mappings don't need lock coordination
        self.lockToken = nil

        #if os(Windows)
        self.mappingHandle = result.mappingHandle
        #endif
    }
}

// MARK: - Consuming Operations

extension IO.Memory.Map.Region {
    /// Unmaps the region and releases all resources.
    ///
    /// This is the canonical way to release a mapping. After calling `unmap()`,
    /// the region cannot be used.
    ///
    /// - Note: This is a consuming function - the region is moved and destroyed.
    public consuming func unmap() {
        guard let base = mappingBaseAddress else { return }

        // Release lock token first
        lockToken?.release()

        // Unmap the region
        #if os(Windows)
        try? IO.Memory.Map.unmap(address: base, mappingHandle: mappingHandle)
        #else
        try? IO.Memory.Map.unmap(address: base, length: mappingLength)
        #endif

        // Mark as unmapped (for deinit safety)
        // Note: In a consuming function, we're destroying self anyway
    }

    /// Remaps the region to a new range.
    ///
    /// This is a consuming operation that:
    /// 1. Unmaps the current region
    /// 2. Creates a new mapping with the specified range
    /// 3. Returns the new region
    ///
    /// - Parameter range: The new range to map.
    /// - Returns: A new `Region` with the specified range.
    /// - Throws: `IO.Memory.Map.Error` if remapping fails.
    ///
    /// - Note: On Linux, this may use `mremap()` for efficiency when possible.
    #if !os(Windows)
    public consuming func remap(
        fileDescriptor: Int32,
        range: Range
    ) throws(IO.Memory.Map.Error) -> Self {
        // Capture values before consuming self
        let capturedAccess = access
        let capturedSharing = sharing
        let capturedSafety = safety

        // For now, we do unmap + map
        // Linux optimization with mremap could be added later
        self.unmap()

        return try Self(
            fileDescriptor: fileDescriptor,
            range: range,
            access: capturedAccess,
            sharing: capturedSharing,
            safety: capturedSafety
        )
    }
    #endif

    #if os(Windows)
    public consuming func remap(
        fileHandle: HANDLE,
        range: Range
    ) throws(IO.Memory.Map.Error) -> Self {
        // Capture values before consuming self
        let capturedAccess = access
        let capturedSharing = sharing
        let capturedSafety = safety

        self.unmap()

        return try Self(
            fileHandle: fileHandle,
            range: range,
            access: capturedAccess,
            sharing: capturedSharing,
            safety: capturedSafety
        )
    }
    #endif
}

// MARK: - Access Methods

extension IO.Memory.Map.Region {
    /// Accesses a byte at the given index.
    ///
    /// - Parameter index: The byte index (0-based).
    /// - Returns: The byte value at that index.
    /// - Precondition: `index` must be in bounds.
    public subscript(index: Int) -> UInt8 {
        precondition(index >= 0 && index < userLength, "Index out of bounds")
        guard let base = baseAddress else {
            preconditionFailure("Mapping is not valid")
        }
        return base.load(fromByteOffset: index, as: UInt8.self)
    }

    /// Provides read-only access to the mapped bytes.
    ///
    /// - Parameter body: A closure that receives an `UnsafeRawBufferPointer`.
    /// - Returns: The result of the closure.
    /// - Throws: Rethrows any error from the closure.
    public func withUnsafeBytes<T>(
        _ body: (UnsafeRawBufferPointer) throws -> T
    ) rethrows -> T {
        guard let base = baseAddress else {
            preconditionFailure("Mapping is not valid")
        }
        let buffer = UnsafeRawBufferPointer(start: base, count: userLength)
        return try body(buffer)
    }

    /// Provides mutable access to the mapped bytes.
    ///
    /// - Parameter body: A closure that receives an `UnsafeMutableRawBufferPointer`.
    /// - Returns: The result of the closure.
    /// - Throws: Rethrows any error from the closure.
    /// - Precondition: The mapping must have write access.
    public func withUnsafeMutableBytes<T>(
        _ body: (UnsafeMutableRawBufferPointer) throws -> T
    ) rethrows -> T {
        precondition(access.allowsWrite, "Mapping does not allow writes")
        guard let base = mutableBaseAddress else {
            preconditionFailure("Mapping is not valid")
        }
        let buffer = UnsafeMutableRawBufferPointer(start: base, count: userLength)
        return try body(buffer)
    }

    /// Writes a byte at the given index.
    ///
    /// - Parameters:
    ///   - value: The byte value to write.
    ///   - index: The byte index (0-based).
    /// - Precondition: The mapping must have write access.
    /// - Precondition: `index` must be in bounds.
    public func write(_ value: UInt8, at index: Int) {
        precondition(access.allowsWrite, "Mapping does not allow writes")
        precondition(index >= 0 && index < userLength, "Index out of bounds")
        guard let base = mutableBaseAddress else {
            preconditionFailure("Mapping is not valid")
        }
        base.storeBytes(of: value, toByteOffset: index, as: UInt8.self)
    }
}

// MARK: - Synchronization

extension IO.Memory.Map.Region {
    /// Synchronizes the mapped region to disk.
    ///
    /// - Parameter async: If `true`, returns immediately and syncs asynchronously.
    /// - Throws: `IO.Memory.Map.Error` if sync fails.
    public func sync(async: Bool = false) throws(IO.Memory.Map.Error) {
        guard let base = mappingBaseAddress else {
            throw .alreadyUnmapped
        }

        do {
            #if os(Windows)
            try IO.Memory.Map.sync(address: base, length: mappingLength)
            #else
            try IO.Memory.Map.sync(address: base, length: mappingLength, async: async)
            #endif
        } catch {
            throw IO.Memory.Map.Error(from: error)
        }
    }

    /// Provides a hint about expected access patterns.
    ///
    /// This is advisory - the system may ignore the hint.
    ///
    /// - Parameter advice: The access pattern hint.
    public func advise(_ advice: IO.Memory.Map.Advice) {
        guard let base = mappingBaseAddress else { return }
        IO.Memory.Map.advise(address: base, length: mappingLength, advice: advice)
    }
}

// MARK: - Debug Description

extension IO.Memory.Map.Region {
    /// A textual representation for debugging.
    ///
    /// Note: ~Copyable types cannot conform to `CustomDebugStringConvertible`.
    public var debugDescription: String {
        let status = isMapped ? "mapped" : "unmapped"
        return "Region(\(status), length: \(userLength), access: \(access), sharing: \(sharing), safety: \(safety))"
    }
}
