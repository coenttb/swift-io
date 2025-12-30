//
//  IO.File.Lock.Token.swift
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

extension IO.File.Lock {
    /// A move-only token representing a held file lock.
    ///
    /// `Token` ensures the lock is released when it goes out of scope.
    /// It is `~Copyable` to prevent accidental duplication of lock ownership.
    ///
    /// ## Usage
    ///
    /// ```swift
    /// let token = try IO.File.Lock.Token(
    ///     descriptor: fd,
    ///     range: .wholeFile,
    ///     mode: .exclusive
    /// )
    /// defer { token.release() }
    ///
    /// // ... use the locked file ...
    /// ```
    ///
    /// ## Lifetime
    ///
    /// - `release()` is the canonical way to release the lock
    /// - `deinit` releases the lock as a backstop
    /// - Once released, the token cannot be used
    public struct Token: ~Copyable, Sendable {
        #if os(Windows)
        private let handle: HANDLE
        #else
        private let descriptor: Int32
        #endif

        private let range: Range
        private let mode: Mode
        private var isReleased: Bool

        #if os(Windows)
        /// Creates a lock token by acquiring a lock on Windows.
        ///
        /// - Parameters:
        ///   - handle: The file handle.
        ///   - range: The byte range to lock.
        ///   - mode: The lock mode (shared or exclusive).
        ///   - acquire: The acquisition strategy (default: `.wait`).
        /// - Throws: `IO.File.Lock.Error` if locking fails.
        public init(
            handle: HANDLE,
            range: Range = .wholeFile,
            mode: Mode,
            acquire: Acquire = .wait
        ) throws(IO.File.Lock.Error) {
            self.handle = handle
            self.range = range
            self.mode = mode
            self.isReleased = false

            try Self.acquireLock(handle: handle, range: range, mode: mode, acquire: acquire)
        }
        #else
        /// Creates a lock token by acquiring a lock on POSIX.
        ///
        /// - Parameters:
        ///   - descriptor: The file descriptor.
        ///   - range: The byte range to lock.
        ///   - mode: The lock mode (shared or exclusive).
        ///   - acquire: The acquisition strategy (default: `.wait`).
        /// - Throws: `IO.File.Lock.Error` if locking fails.
        public init(
            descriptor: Int32,
            range: Range = .wholeFile,
            mode: Mode,
            acquire: Acquire = .wait
        ) throws(IO.File.Lock.Error) {
            self.descriptor = descriptor
            self.range = range
            self.mode = mode
            self.isReleased = false

            try Self.acquireLock(descriptor: descriptor, range: range, mode: mode, acquire: acquire)
        }
        #endif

        /// Releases the lock.
        ///
        /// This is the canonical way to release the lock. After calling,
        /// the token is consumed and cannot be used.
        ///
        /// - Note: This is a best-effort, non-throwing operation. Unlock errors
        ///   (rare, but possible on Windows with range/state mismatches) are ignored.
        ///   The token is marked as released regardless of whether the unlock syscall
        ///   succeeded, preventing double-unlock attempts in `deinit`.
        public consuming func release() {
            guard !isReleased else { return }
            isReleased = true

            #if os(Windows)
            try? IO.File.Lock.unlock(handle: handle, range: range)
            #else
            try? IO.File.Lock.unlock(descriptor: descriptor, range: range)
            #endif
        }

        deinit {
            guard !isReleased else { return }

            #if os(Windows)
            try? IO.File.Lock.unlock(handle: handle, range: range)
            #else
            try? IO.File.Lock.unlock(descriptor: descriptor, range: range)
            #endif
        }
    }
}

// MARK: - Acquisition Logic

extension IO.File.Lock.Token {
    #if os(Windows)
    /// Acquires a lock using the specified strategy.
    private static func acquireLock(
        handle: HANDLE,
        range: IO.File.Lock.Range,
        mode: IO.File.Lock.Mode,
        acquire: IO.File.Lock.Acquire
    ) throws(IO.File.Lock.Error) {
        switch acquire {
        case .try:
            let acquired: Bool
            do {
                acquired = try IO.File.Lock.tryLock(handle: handle, range: range, mode: mode)
            } catch {
                throw IO.File.Lock.Error(from: error)
            }
            if !acquired {
                throw .wouldBlock
            }

        case .wait:
            do {
                try IO.File.Lock.lock(handle: handle, range: range, mode: mode)
            } catch {
                throw IO.File.Lock.Error(from: error)
            }

        case .deadline(let deadline):
            try acquireWithDeadline(
                handle: handle,
                range: range,
                mode: mode,
                deadline: deadline
            )
        }
    }

    /// Polls for a lock until the deadline expires.
    private static func acquireWithDeadline(
        handle: HANDLE,
        range: IO.File.Lock.Range,
        mode: IO.File.Lock.Mode,
        deadline: IO.File.Lock.Acquire.Deadline
    ) throws(IO.File.Lock.Error) {
        // Exponential backoff: start at 1ms, max 100ms
        var backoffMs: UInt32 = 1

        while true {
            // Check deadline first
            let now = ContinuousClock.Instant.now
            if now >= deadline {
                throw .timedOut
            }

            // Try to acquire
            let acquired: Bool
            do {
                acquired = try IO.File.Lock.tryLock(handle: handle, range: range, mode: mode)
            } catch {
                throw IO.File.Lock.Error(from: error)
            }

            if acquired {
                // Critical: re-check deadline after acquisition
                // If deadline passed, unlock and throw to maintain invariant:
                // "success means lock was acquired before deadline"
                if ContinuousClock.Instant.now >= deadline {
                    try? IO.File.Lock.unlock(handle: handle, range: range)
                    throw .timedOut
                }
                return
            }

            // Calculate sleep time (don't overshoot deadline)
            let remaining = deadline - ContinuousClock.Instant.now
            let remainingMs = durationToMilliseconds(remaining)

            if remainingMs == 0 {
                throw .timedOut
            }

            let sleepMs = min(backoffMs, remainingMs)
            Sleep(sleepMs)

            // Exponential backoff with cap
            backoffMs = min(backoffMs * 2, 100)
        }
    }

    /// Converts Duration to milliseconds, clamped to UInt32 range.
    private static func durationToMilliseconds(_ duration: Duration) -> UInt32 {
        // Duration stores (seconds, attoseconds) where 1 attosecond = 10^-18 seconds
        let (seconds, attoseconds) = duration.components
        if seconds < 0 { return 0 }
        if seconds > Int64(UInt32.max / 1000) { return UInt32.max }

        let ms = UInt64(seconds) * 1000 + UInt64(attoseconds) / 1_000_000_000_000_000
        return UInt32(min(ms, UInt64(UInt32.max)))
    }
    #else
    /// Acquires a lock using the specified strategy.
    private static func acquireLock(
        descriptor: Int32,
        range: IO.File.Lock.Range,
        mode: IO.File.Lock.Mode,
        acquire: IO.File.Lock.Acquire
    ) throws(IO.File.Lock.Error) {
        switch acquire {
        case .try:
            let acquired: Bool
            do {
                acquired = try IO.File.Lock.tryLock(descriptor: descriptor, range: range, mode: mode)
            } catch {
                throw IO.File.Lock.Error(from: error)
            }
            if !acquired {
                throw .wouldBlock
            }

        case .wait:
            do {
                try IO.File.Lock.lock(descriptor: descriptor, range: range, mode: mode)
            } catch {
                throw IO.File.Lock.Error(from: error)
            }

        case .deadline(let deadline):
            try acquireWithDeadline(
                descriptor: descriptor,
                range: range,
                mode: mode,
                deadline: deadline
            )
        }
    }

    /// Polls for a lock until the deadline expires.
    private static func acquireWithDeadline(
        descriptor: Int32,
        range: IO.File.Lock.Range,
        mode: IO.File.Lock.Mode,
        deadline: IO.File.Lock.Acquire.Deadline
    ) throws(IO.File.Lock.Error) {
        // Exponential backoff: start at 1ms, max 100ms
        var backoffNs: UInt64 = 1_000_000  // 1ms in nanoseconds

        while true {
            // Check deadline first
            let now = ContinuousClock.Instant.now
            if now >= deadline {
                throw .timedOut
            }

            // Try to acquire
            let acquired: Bool
            do {
                acquired = try IO.File.Lock.tryLock(descriptor: descriptor, range: range, mode: mode)
            } catch {
                throw IO.File.Lock.Error(from: error)
            }

            if acquired {
                // Critical: re-check deadline after acquisition
                // If deadline passed, unlock and throw to maintain invariant:
                // "success means lock was acquired before deadline"
                if ContinuousClock.Instant.now >= deadline {
                    try? IO.File.Lock.unlock(descriptor: descriptor, range: range)
                    throw .timedOut
                }
                return
            }

            // Calculate sleep time (don't overshoot deadline)
            let remaining = deadline - ContinuousClock.Instant.now
            let remainingNs = durationToNanoseconds(remaining)

            if remainingNs == 0 {
                throw .timedOut
            }

            let sleepNs = min(backoffNs, remainingNs)
            var ts = timespec()
            ts.tv_sec = Int(sleepNs / 1_000_000_000)
            ts.tv_nsec = Int(sleepNs % 1_000_000_000)
            nanosleep(&ts, nil)

            // Exponential backoff with cap at 100ms
            backoffNs = min(backoffNs * 2, 100_000_000)
        }
    }

    /// Converts Duration to nanoseconds, clamped to UInt64 range.
    private static func durationToNanoseconds(_ duration: Duration) -> UInt64 {
        // Duration stores (seconds, attoseconds) where 1 attosecond = 10^-18 seconds
        let (seconds, attoseconds) = duration.components
        if seconds < 0 { return 0 }
        if seconds > Int64(UInt64.max / 1_000_000_000) { return UInt64.max }

        let ns = UInt64(seconds) * 1_000_000_000 + UInt64(attoseconds) / 1_000_000_000
        return ns
    }
    #endif
}

// MARK: - Scoped Locking

extension IO.File.Lock {
    #if !os(Windows)
    /// Executes a closure while holding an exclusive lock.
    ///
    /// The lock is automatically released when the closure completes.
    ///
    /// - Parameters:
    ///   - descriptor: The file descriptor.
    ///   - range: The byte range to lock (default: whole file).
    ///   - acquire: The acquisition strategy (default: `.wait`).
    ///   - body: The closure to execute while holding the lock.
    /// - Returns: The result of the closure.
    /// - Throws: `IO.File.Lock.Error` if locking fails, or rethrows from the closure.
    public static func withExclusive<T>(
        descriptor: Int32,
        range: Range = .wholeFile,
        acquire: Acquire = .wait,
        _ body: () throws -> T
    ) throws -> T {
        let token = try Token(descriptor: descriptor, range: range, mode: .exclusive, acquire: acquire)
        let result = try body()
        _ = consume token
        return result
    }

    /// Executes a closure while holding a shared lock.
    ///
    /// The lock is automatically released when the closure completes.
    ///
    /// - Parameters:
    ///   - descriptor: The file descriptor.
    ///   - range: The byte range to lock (default: whole file).
    ///   - acquire: The acquisition strategy (default: `.wait`).
    ///   - body: The closure to execute while holding the lock.
    /// - Returns: The result of the closure.
    /// - Throws: `IO.File.Lock.Error` if locking fails, or rethrows from the closure.
    public static func withShared<T>(
        descriptor: Int32,
        range: Range = .wholeFile,
        acquire: Acquire = .wait,
        _ body: () throws -> T
    ) throws -> T {
        let token = try Token(descriptor: descriptor, range: range, mode: .shared, acquire: acquire)
        let result = try body()
        _ = consume token
        return result
    }
    #endif

    #if os(Windows)
    /// Executes a closure while holding an exclusive lock.
    ///
    /// The lock is automatically released when the closure completes.
    ///
    /// - Parameters:
    ///   - handle: The file handle.
    ///   - range: The byte range to lock (default: whole file).
    ///   - acquire: The acquisition strategy (default: `.wait`).
    ///   - body: The closure to execute while holding the lock.
    /// - Returns: The result of the closure.
    /// - Throws: `IO.File.Lock.Error` if locking fails, or rethrows from the closure.
    public static func withExclusive<T>(
        handle: HANDLE,
        range: Range = .wholeFile,
        acquire: Acquire = .wait,
        _ body: () throws -> T
    ) throws -> T {
        let token = try Token(handle: handle, range: range, mode: .exclusive, acquire: acquire)
        let result = try body()
        _ = consume token
        return result
    }

    /// Executes a closure while holding a shared lock.
    ///
    /// The lock is automatically released when the closure completes.
    ///
    /// - Parameters:
    ///   - handle: The file handle.
    ///   - range: The byte range to lock (default: whole file).
    ///   - acquire: The acquisition strategy (default: `.wait`).
    ///   - body: The closure to execute while holding the lock.
    /// - Returns: The result of the closure.
    /// - Throws: `IO.File.Lock.Error` if locking fails, or rethrows from the closure.
    public static func withShared<T>(
        handle: HANDLE,
        range: Range = .wholeFile,
        acquire: Acquire = .wait,
        _ body: () throws -> T
    ) throws -> T {
        let token = try Token(handle: handle, range: range, mode: .shared, acquire: acquire)
        let result = try body()
        _ = consume token
        return result
    }
    #endif
}
