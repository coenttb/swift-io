//
//  IO.File.Lock.Syscalls.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 30/12/2025.
//
//  Package-internal syscall wrappers for file locking.
//  Platform imports are quarantined to this file.
//

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#elseif os(Windows)
    import WinSDK
#endif

// MARK: - Lock Mode

extension IO.File.Lock {
    /// Lock mode for file locking operations.
    public enum Mode: Sendable, Equatable {
        /// Shared (read) lock - multiple processes can hold simultaneously.
        case shared

        /// Exclusive (write) lock - only one process can hold.
        case exclusive
    }
}

// MARK: - Lock Range

extension IO.File.Lock {
    /// A byte range for locking.
    ///
    /// This is an enum to make `.wholeFile` a first-class semantic case,
    /// not just a numeric sentinel. This avoids overflow issues on Windows
    /// and makes intent explicit.
    public enum Range: Sendable, Equatable {
        /// Lock the entire file.
        ///
        /// This is the canonical representation for whole-file locking.
        /// Platform semantics:
        /// - POSIX: Uses `l_len = 0` (lock to EOF)
        /// - Windows: Uses max length from offset 0
        case wholeFile

        /// Lock a specific byte range.
        ///
        /// - Parameters:
        ///   - start: Start offset (inclusive).
        ///   - end: End offset (exclusive).
        case bytes(start: UInt64, end: UInt64)

        /// Creates a byte range from a Swift Range.
        public init(_ range: Swift.Range<UInt64>) {
            self = .bytes(start: range.lowerBound, end: range.upperBound)
        }

        /// Convenience initializer for byte ranges.
        public init(start: UInt64, end: UInt64) {
            precondition(start <= end, "Range start must be <= end")
            self = .bytes(start: start, end: end)
        }

        /// The start offset (0 for wholeFile).
        public var start: UInt64 {
            switch self {
            case .wholeFile: return 0
            case .bytes(let start, _): return start
            }
        }

        /// The length of the range (UInt64.max for wholeFile).
        public var length: UInt64 {
            switch self {
            case .wholeFile: return UInt64.max
            case .bytes(let start, let end): return end - start
            }
        }
    }
}

// MARK: - POSIX Implementation

#if !os(Windows)
extension IO.File.Lock {
    /// Acquires a lock on a byte range (blocking).
    ///
    /// - Parameters:
    ///   - descriptor: The file descriptor.
    ///   - range: The byte range to lock.
    ///   - mode: The lock mode (shared or exclusive).
    /// - Throws: `Error.Syscall` if locking fails.
    package static func lock(
        descriptor: Int32,
        range: Range,
        mode: Mode
    ) throws(Error.Syscall) {
        var flock = makeFlock(range: range, mode: mode, type: .lock)

        let result = fcntl(descriptor, F_SETLKW, &flock)
        guard result != -1 else {
            throw .posix(errno: errno, operation: .lock)
        }
    }

    /// Attempts to acquire a lock without blocking.
    ///
    /// - Parameters:
    ///   - descriptor: The file descriptor.
    ///   - range: The byte range to lock.
    ///   - mode: The lock mode (shared or exclusive).
    /// - Returns: `true` if the lock was acquired, `false` if it would block.
    /// - Throws: `Error.Syscall` for errors other than "would block".
    package static func tryLock(
        descriptor: Int32,
        range: Range,
        mode: Mode
    ) throws(Error.Syscall) -> Bool {
        var flock = makeFlock(range: range, mode: mode, type: .lock)

        let result = fcntl(descriptor, F_SETLK, &flock)
        if result == -1 {
            // EAGAIN or EACCES means the lock is held by another process
            if errno == EAGAIN || errno == EACCES {
                return false
            }
            throw .posix(errno: errno, operation: .tryLock)
        }
        return true
    }

    /// Releases a lock on a byte range.
    ///
    /// - Parameters:
    ///   - descriptor: The file descriptor.
    ///   - range: The byte range to unlock.
    /// - Throws: `Error.Syscall` if unlocking fails.
    package static func unlock(
        descriptor: Int32,
        range: Range
    ) throws(Error.Syscall) {
        var flock = makeFlock(range: range, mode: .shared, type: .unlock)

        let result = fcntl(descriptor, F_SETLK, &flock)
        guard result != -1 else {
            throw .posix(errno: errno, operation: .unlock)
        }
    }

    /// Creates a flock structure for fcntl.
    private static func makeFlock(
        range: Range,
        mode: Mode,
        type: FlockType
    ) -> flock {
        var flock = flock()

        switch type {
        case .lock:
            flock.l_type = mode == .shared ? Int16(F_RDLCK) : Int16(F_WRLCK)
        case .unlock:
            flock.l_type = Int16(F_UNLCK)
        }

        flock.l_whence = Int16(SEEK_SET)

        // Handle range cases explicitly
        switch range {
        case .wholeFile:
            // l_start = 0, l_len = 0 means "lock entire file to EOF"
            flock.l_start = 0
            flock.l_len = 0
        case .bytes(let start, let end):
            flock.l_start = off_t(start)
            flock.l_len = off_t(end - start)
        }

        return flock
    }

    private enum FlockType {
        case lock
        case unlock
    }
}
#endif

// MARK: - Windows Implementation

#if os(Windows)
extension IO.File.Lock {
    /// Acquires a lock on a byte range (blocking).
    ///
    /// - Parameters:
    ///   - handle: The file handle.
    ///   - range: The byte range to lock.
    ///   - mode: The lock mode (shared or exclusive).
    /// - Throws: `Error.Syscall` if locking fails.
    package static func lock(
        handle: HANDLE,
        range: Range,
        mode: Mode
    ) throws(Error.Syscall) {
        guard handle != INVALID_HANDLE_VALUE else {
            throw .invalidDescriptor(operation: .lock)
        }

        var overlapped = makeOverlapped(start: range.start)

        // Handle .wholeFile specially: Windows locks exact byte counts (no "to EOF" like POSIX).
        // Using max DWORD values covers any possible file size.
        let (lengthLow, lengthHigh) = computeLockLength(range: range)

        // For true blocking, we don't use LOCKFILE_FAIL_IMMEDIATELY
        let flags: DWORD = mode == .exclusive ? DWORD(LOCKFILE_EXCLUSIVE_LOCK) : 0

        let result = LockFileEx(
            handle,
            flags,
            0,
            lengthLow,
            lengthHigh,
            &overlapped
        )

        guard result != 0 else {
            throw .windows(code: GetLastError(), operation: .lock)
        }
    }

    /// Attempts to acquire a lock without blocking.
    ///
    /// - Parameters:
    ///   - handle: The file handle.
    ///   - range: The byte range to lock.
    ///   - mode: The lock mode (shared or exclusive).
    /// - Returns: `true` if the lock was acquired, `false` if it would block.
    /// - Throws: `Error.Syscall` for errors other than "would block".
    package static func tryLock(
        handle: HANDLE,
        range: Range,
        mode: Mode
    ) throws(Error.Syscall) -> Bool {
        guard handle != INVALID_HANDLE_VALUE else {
            throw .invalidDescriptor(operation: .tryLock)
        }

        var overlapped = makeOverlapped(start: range.start)
        let (lengthLow, lengthHigh) = computeLockLength(range: range)

        var flags: DWORD = DWORD(LOCKFILE_FAIL_IMMEDIATELY)
        if mode == .exclusive {
            flags |= DWORD(LOCKFILE_EXCLUSIVE_LOCK)
        }

        let result = LockFileEx(
            handle,
            flags,
            0,
            lengthLow,
            lengthHigh,
            &overlapped
        )

        if result == 0 {
            let error = GetLastError()
            if error == DWORD(ERROR_LOCK_VIOLATION) || error == DWORD(ERROR_LOCK_FAILED) {
                return false
            }
            throw .windows(code: error, operation: .tryLock)
        }
        return true
    }

    /// Releases a lock on a byte range.
    ///
    /// - Parameters:
    ///   - handle: The file handle.
    ///   - range: The byte range to unlock.
    /// - Throws: `Error.Syscall` if unlocking fails.
    package static func unlock(
        handle: HANDLE,
        range: Range
    ) throws(Error.Syscall) {
        guard handle != INVALID_HANDLE_VALUE else {
            throw .invalidDescriptor(operation: .unlock)
        }

        var overlapped = makeOverlapped(start: range.start)
        let (lengthLow, lengthHigh) = computeLockLength(range: range)

        let result = UnlockFileEx(
            handle,
            0,
            lengthLow,
            lengthHigh,
            &overlapped
        )

        guard result != 0 else {
            throw .windows(code: GetLastError(), operation: .unlock)
        }
    }

    /// Creates an OVERLAPPED structure for the given start offset.
    private static func makeOverlapped(start: UInt64) -> OVERLAPPED {
        var overlapped = OVERLAPPED()
        overlapped.Offset = DWORD(start & 0xFFFFFFFF)
        overlapped.OffsetHigh = DWORD(start >> 32)
        return overlapped
    }

    /// Computes the DWORD pair for the lock length.
    ///
    /// Windows LockFileEx locks exact byte counts (unlike POSIX's "to EOF" with l_len=0).
    private static func computeLockLength(range: Range) -> (low: DWORD, high: DWORD) {
        switch range {
        case .wholeFile:
            // Use max DWORD values to lock the largest possible range from offset 0.
            // This is the Windows equivalent of "lock entire file".
            return (DWORD.max, DWORD.max)
        case .bytes(let start, let end):
            let length = end - start
            return (DWORD(length & 0xFFFFFFFF), DWORD(length >> 32))
        }
    }
}
#endif
