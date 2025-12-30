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

        /// Placeholder for future lock token when `.coordinated` safety is used.
        /// This will be replaced with actual lock token in Phase 2.
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

        /// Map the whole file (size snapshot at map time).
        ///
        /// - Parameter fileSize: The file size to use (must be provided by caller).
        case wholeFile(fileSize: Int)

        /// The starting offset.
        public var offset: Int {
            switch self {
            case .bytes(let offset, _): return offset
            case .wholeFile: return 0
            }
        }

        /// The length to map.
        public var length: Int {
            switch self {
            case .bytes(_, let length): return length
            case .wholeFile(let fileSize): return fileSize
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

// MARK: - Placeholder Lock Token

extension IO.Memory.Map.Region {
    /// Placeholder lock token for Phase 1.
    ///
    /// This will be replaced with `IO.File.Lock.Token` in Phase 2.
    /// For now, it's a no-op placeholder that maintains API compatibility.
    struct LockToken: Sendable {
        // In Phase 2, this will hold the actual lock
        // For now, it just tracks that a lock was requested

        let mode: Safety.LockMode
        let scope: Safety.LockScope
        let range: (start: Int, end: Int)

        func release() {
            // No-op in Phase 1
            // In Phase 2, this will release the file lock
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

        // Calculate alignment
        let requestedOffset = range.offset
        let alignedOffset = IO.Memory.alignOffsetDown(requestedOffset)
        let delta = requestedOffset - alignedOffset
        let userLen = range.length
        let mappingLen = IO.Memory.alignLengthUp(userLen + delta)

        // Adjust sharing for copyOnWrite access
        let effectiveSharing: Sharing = (access == .copyOnWrite) ? .private : sharing

        // Perform the mapping
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

        self.mappingBaseAddress = result.baseAddress
        self.mappingLength = result.mappedLength
        self.offsetDelta = delta
        self.userLength = userLen
        self.access = access
        self.sharing = effectiveSharing
        self.safety = effectiveSafety

        // Create placeholder lock token if coordinated
        if case .coordinated(let mode, let scope) = effectiveSafety {
            let lockRange = self.computeLockRange(scope: scope, alignedOffset: alignedOffset, mappingLength: mappingLen)
            self.lockToken = LockToken(mode: mode, scope: scope, range: lockRange)
        } else {
            self.lockToken = nil
        }
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

        // Calculate alignment (Windows uses 64KB granularity)
        let requestedOffset = range.offset
        let alignedOffset = IO.Memory.alignOffsetDown(requestedOffset)
        let delta = requestedOffset - alignedOffset
        let userLen = range.length
        let mappingLen = IO.Memory.alignLengthUp(userLen + delta)

        // Adjust sharing for copyOnWrite access
        let effectiveSharing: Sharing = (access == .copyOnWrite) ? .private : sharing

        // Perform the mapping
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

        self.mappingBaseAddress = result.baseAddress
        self.mappingLength = result.mappedLength
        self.offsetDelta = delta
        self.userLength = userLen
        self.access = access
        self.sharing = effectiveSharing
        self.safety = effectiveSafety
        self.mappingHandle = result.mappingHandle

        // Create placeholder lock token if coordinated
        if case .coordinated(let mode, let scope) = effectiveSafety {
            let lockRange = self.computeLockRange(scope: scope, alignedOffset: alignedOffset, mappingLength: mappingLen)
            self.lockToken = LockToken(mode: mode, scope: scope, range: lockRange)
        } else {
            self.lockToken = nil
        }
    }
    #endif

    /// Computes the lock range based on scope.
    private func computeLockRange(scope: Safety.LockScope, alignedOffset: Int, mappingLength: Int) -> (start: Int, end: Int) {
        switch scope {
        case .wholeFile:
            return (0, Int.max)
        case .mappedRange:
            return (alignedOffset, alignedOffset + mappingLength)
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

        // Release lock token first (in Phase 2, this will actually release the lock)
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
