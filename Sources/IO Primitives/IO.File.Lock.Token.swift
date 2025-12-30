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
        ///   - mode: The lock mode.
        ///   - blocking: If `true`, waits for the lock. If `false`, fails immediately if locked.
        /// - Throws: `IO.File.Lock.Error` if locking fails.
        public init(
            handle: HANDLE,
            range: Range,
            mode: Mode,
            blocking: Bool = true
        ) throws(IO.File.Lock.Error) {
            self.handle = handle
            self.range = range
            self.mode = mode
            self.isReleased = false

            if blocking {
                do {
                    try IO.File.Lock.lock(handle: handle, range: range, mode: mode)
                } catch {
                    throw IO.File.Lock.Error(from: error)
                }
            } else {
                let acquired: Bool
                do {
                    acquired = try IO.File.Lock.tryLock(handle: handle, range: range, mode: mode)
                } catch {
                    throw IO.File.Lock.Error(from: error)
                }
                if !acquired {
                    throw IO.File.Lock.Error.wouldBlock
                }
            }
        }
        #else
        /// Creates a lock token by acquiring a lock on POSIX.
        ///
        /// - Parameters:
        ///   - descriptor: The file descriptor.
        ///   - range: The byte range to lock.
        ///   - mode: The lock mode.
        ///   - blocking: If `true`, waits for the lock. If `false`, fails immediately if locked.
        /// - Throws: `IO.File.Lock.Error` if locking fails.
        public init(
            descriptor: Int32,
            range: Range,
            mode: Mode,
            blocking: Bool = true
        ) throws(IO.File.Lock.Error) {
            self.descriptor = descriptor
            self.range = range
            self.mode = mode
            self.isReleased = false

            if blocking {
                do {
                    try IO.File.Lock.lock(descriptor: descriptor, range: range, mode: mode)
                } catch {
                    throw IO.File.Lock.Error(from: error)
                }
            } else {
                let acquired: Bool
                do {
                    acquired = try IO.File.Lock.tryLock(descriptor: descriptor, range: range, mode: mode)
                } catch {
                    throw IO.File.Lock.Error(from: error)
                }
                if !acquired {
                    throw IO.File.Lock.Error.wouldBlock
                }
            }
        }
        #endif

        /// Releases the lock.
        ///
        /// This is the canonical way to release the lock. After calling,
        /// the token is consumed and cannot be used.
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

// MARK: - Scoped Locking

extension IO.File.Lock {
    /// Executes a closure while holding an exclusive lock.
    ///
    /// The lock is automatically released when the closure completes.
    ///
    /// - Parameters:
    ///   - descriptor: The file descriptor.
    ///   - range: The byte range to lock (default: whole file).
    ///   - body: The closure to execute while holding the lock.
    /// - Returns: The result of the closure.
    /// - Throws: `IO.File.Lock.Error` if locking fails, or rethrows from the closure.
    #if !os(Windows)
    public static func withExclusive<T>(
        descriptor: Int32,
        range: Range = .wholeFile,
        _ body: () throws -> T
    ) throws -> T {
        let token = try Token(descriptor: descriptor, range: range, mode: .exclusive)
        let result = try body()
        _ = consume token  // Token released by deinit
        return result
    }

    /// Executes a closure while holding a shared lock.
    ///
    /// The lock is automatically released when the closure completes.
    ///
    /// - Parameters:
    ///   - descriptor: The file descriptor.
    ///   - range: The byte range to lock (default: whole file).
    ///   - body: The closure to execute while holding the lock.
    /// - Returns: The result of the closure.
    /// - Throws: `IO.File.Lock.Error` if locking fails, or rethrows from the closure.
    public static func withShared<T>(
        descriptor: Int32,
        range: Range = .wholeFile,
        _ body: () throws -> T
    ) throws -> T {
        let token = try Token(descriptor: descriptor, range: range, mode: .shared)
        let result = try body()
        _ = consume token
        return result
    }
    #endif

    #if os(Windows)
    /// Executes a closure while holding an exclusive lock.
    ///
    /// The lock is automatically released when the closure completes.
    public static func withExclusive<T>(
        handle: HANDLE,
        range: Range = .wholeFile,
        _ body: () throws -> T
    ) throws -> T {
        let token = try Token(handle: handle, range: range, mode: .exclusive)
        let result = try body()
        _ = consume token
        return result
    }

    /// Executes a closure while holding a shared lock.
    ///
    /// The lock is automatically released when the closure completes.
    public static func withShared<T>(
        handle: HANDLE,
        range: Range = .wholeFile,
        _ body: () throws -> T
    ) throws -> T {
        let token = try Token(handle: handle, range: range, mode: .shared)
        let result = try body()
        _ = consume token
        return result
    }
    #endif
}
