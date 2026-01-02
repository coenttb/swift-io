//
//  IO.Event.Channel.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 29/12/2025.
//

public import Binary
public import IO_Primitives

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

extension IO.Event {
    /// A non-blocking I/O channel for socket-based read and write operations.
    ///
    /// Channel provides the user-facing API for non-blocking I/O operations on sockets.
    /// It wraps a socket file descriptor registered with a `Selector` and handles:
    /// - Async read/write with automatic retry on `EAGAIN`/`EWOULDBLOCK`
    /// - Half-close state tracking via `shutdown(2)`
    /// - Cancellation via Swift's structured concurrency
    ///
    /// ## Socket-Only
    ///
    /// This type is designed for socket file descriptors. It uses `shutdown(2)` for
    /// half-close and `getsockopt(SO_ERROR)` for error detection. For non-socket
    /// descriptors (pipes, files), use a lower-level API.
    ///
    /// ## Serialization (v1 Constraint)
    ///
    /// **This version serializes all operations.** Channel is `~Copyable` (move-only),
    /// ensuring single ownership. Concurrent `read()` and `write()` calls from different
    /// tasks are not supported in v1. Future versions may support full-duplex I/O.
    ///
    /// ## Usage
    /// ```swift
    /// let channel = try await Channel.wrap(socketFd, selector: selector, interest: .read)
    /// defer { Task { try? await channel.close() } }
    ///
    /// var buffer = [UInt8](repeating: 0, count: 1024)
    /// let bytesRead = try await channel.read(into: &buffer)
    /// ```
    ///
    /// ## Half-Close
    ///
    /// Channels support independent shutdown of read and write directions:
    /// - `shutdownRead()`: Signals no more reads, kernel may send FIN
    /// - `shutdownWrite()`: Signals no more writes, kernel sends FIN
    /// - `close()`: Closes both directions and releases resources
    ///
    /// ## Cancellation
    ///
    /// Task cancellation causes in-progress operations to throw `.cancelled`.
    /// The channel remains in a consistent state after cancellation.
    public struct Channel: ~Copyable, Sendable {
        /// The selector this channel is registered with.
        private let selector: Selector

        /// The underlying file descriptor.
        private let descriptor: Int32

        /// The registration ID.
        private let id: ID

        /// Actor for lifecycle state synchronization.
        private let lifecycle: Lifecycle

        /// Token phase: registering (before first arm) or armed (after first arm).
        /// Uses two optionals to maintain proper typestate - never fabricate tokens.
        private var registering: Token<Registering>?
        private var armed: Token<Armed>?

        /// Private initializer - use `wrap()` factory.
        private init(
            selector: Selector,
            descriptor: Int32,
            id: ID,
            token: consuming Token<Registering>
        ) {
            self.selector = selector
            self.descriptor = descriptor
            self.id = id
            self.lifecycle = Lifecycle()
            // Store the actual token - no fabrication
            self.registering = consume token
            self.armed = nil
        }

        /// Wrap an existing socket file descriptor in a Channel.
        ///
        /// The descriptor must already be set to non-blocking mode.
        /// The Channel takes ownership and will close it on `close()`.
        ///
        /// - Parameters:
        ///   - descriptor: The socket file descriptor to wrap.
        ///   - selector: The selector to register with.
        ///   - interest: Initial interest (typically `.read` or [.read, .write]).
        /// - Returns: A new Channel.
        /// - Throws: If registration fails.
        public static func wrap(
            _ descriptor: Int32,
            selector: Selector,
            interest: Interest
        ) async throws(Failure) -> Channel {
            let result = try await selector.register(descriptor, interest: interest)
            return Channel(
                selector: selector,
                descriptor: descriptor,
                id: result.id,
                token: result.token
            )
        }

        // MARK: - Read

        /// Read bytes into a buffer.
        ///
        /// Reads up to `buffer.count` bytes. Returns the number of bytes read,
        /// which may be less than the buffer capacity.
        ///
        /// - Parameter buffer: The buffer to read into.
        /// - Returns: The number of bytes read, or 0 on EOF.
        /// - Throws: `Failure` on error or cancellation.
        ///
        /// ## EOF Detection
        ///
        /// Returns 0 when the peer has closed the connection (EOF).
        /// If the buffer has capacity 0, returns 0 without implying EOF -
        /// no state transition occurs.
        ///
        /// ## Cancellation
        ///
        /// If the task is cancelled while waiting for readiness, throws `.cancelled`.
        public mutating func read<B: Binary.Mutable>(
            into buffer: inout B
        ) async throws(Failure) -> Int {
            // Check half-close state
            if await lifecycle.isReadClosed {
                return 0  // EOF
            }

            // Handle zero-capacity buffer (not EOF, no state transition)
            let capacity = buffer.withUnsafeMutableBytes { $0.count }
            if capacity == 0 {
                return 0
            }

            // Read loop with retry on EAGAIN
            while true {
                let result = buffer.withUnsafeMutableBytes { ptr -> ReadResult in
                    let n = systemRead(descriptor, ptr.baseAddress, ptr.count)
                    if n > 0 {
                        return .read(n)
                    } else if n == 0 {
                        return .eof
                    } else {
                        let err = errno
                        if err == EAGAIN || err == EWOULDBLOCK {
                            return .wouldBlock
                        } else {
                            return .error(err)
                        }
                    }
                }

                switch result {
                case .read(let n):
                    return n

                case .eof:
                    // True EOF - transition state
                    await lifecycle.close.read()
                    return 0

                case .wouldBlock:
                    // Arm for read readiness, restoring token on error
                    try await arm(for: .read)
                // Continue loop to retry read

                case .error(let err):
                    throw .failure(.platform(errno: err))
                }
            }
        }

        // MARK: - Write

        /// Write bytes from a buffer.
        ///
        /// Writes up to `buffer.count` bytes. Returns the number of bytes written,
        /// which may be less than the buffer size (partial write).
        ///
        /// - Parameter buffer: The buffer to write from.
        /// - Returns: The number of bytes written.
        /// - Throws: `Failure` on error or cancellation.
        ///
        /// ## Partial Writes
        ///
        /// The caller must loop to write the complete buffer if needed:
        /// ```swift
        /// var offset = 0
        /// while offset < data.count {
        ///     let slice = data[offset...]
        ///     offset += try await channel.write(Array(slice))
        /// }
        /// ```
        public mutating func write<B: Binary.Contiguous>(
            _ buffer: borrowing B
        ) async throws(Failure) -> Int {
            // Check half-close state
            if await lifecycle.isWriteClosed {
                throw .failure(.writeClosed)
            }

            // Handle zero-length buffer
            let length = buffer.withUnsafeBytes { $0.count }
            if length == 0 {
                return 0
            }

            // Write loop with retry on EAGAIN
            while true {
                let result = buffer.withUnsafeBytes { ptr -> WriteResult in
                    let n = systemWrite(descriptor, ptr.baseAddress, ptr.count)
                    if n > 0 {
                        return .wrote(n)
                    } else if n == 0 {
                        // Treat write returning 0 on non-empty buffer as wouldBlock
                        // to prevent tight loops on exotic descriptors
                        return .wouldBlock
                    } else {
                        let err = errno
                        if err == EAGAIN || err == EWOULDBLOCK {
                            return .wouldBlock
                        } else {
                            return .error(err)
                        }
                    }
                }

                switch result {
                case .wrote(let n):
                    return n

                case .wouldBlock:
                    // Arm for write readiness, restoring token on error
                    try await arm(for: .write)
                // Continue loop to retry write

                case .error(let err):
                    throw .failure(.platform(errno: err))
                }
            }
        }

        // MARK: - Arming Helpers

        /// Arm for the specified interest.
        ///
        /// Uses `armPreservingToken` to ensure the token is always restored on failure.
        /// This keeps the channel in a consistent state even after cancellation or shutdown.
        ///
        /// - Parameter interest: The interest to arm for (`.read` or `.write`).
        private mutating func arm(for interest: IO.Event.Interest) async throws(Failure) {
            // Try registering token first (swap to extract)
            var takenRegistering: Token<Registering>? = nil
            swap(&registering, &takenRegistering)

            if let taken = takenRegistering {
                switch await selector.armPreservingToken(consume taken, interest: interest) {
                case .armed(let result):
                    armed = consume result.token
                    // Check for socket error
                    if result.event.flags.contains(.error) {
                        if let err = pendingSocketError() {
                            throw Failure.failure(.platform(errno: err))
                        }
                    }
                case .failed(token: let restoredToken, let failure):
                    // Restore the token and rethrow - channel remains usable
                    registering = consume restoredToken
                    throw failure
                }
                return
            }

            // Try armed token (swap to extract)
            var takenArmed: Token<Armed>? = nil
            swap(&armed, &takenArmed)

            if let taken = takenArmed {
                switch await selector.armPreservingToken(consume taken, interest: interest) {
                case .armed(let result):
                    armed = consume result.token
                    // Check for socket error
                    if result.event.flags.contains(.error) {
                        if let err = pendingSocketError() {
                            throw Failure.failure(.platform(errno: err))
                        }
                    }
                case .failed(token: let restoredToken, let failure):
                    // Restore the token and rethrow - channel remains usable
                    armed = consume restoredToken
                    throw failure
                }
                return
            }

            preconditionFailure("No token available - concurrent operation or already closed?")
        }

        // MARK: - Connect Support

        /// Wait for write readiness without performing I/O.
        ///
        /// Used for non-blocking connect completion. After connect() returns EINPROGRESS,
        /// call this to wait for the connection to complete, then check SO_ERROR.
        ///
        /// Note: This method does NOT check error flags. For connect, always check
        /// SO_ERROR unconditionally after this returns.
        ///
        /// - Throws: `Failure` on selector error or cancellation.
        @_spi(Internal)
        public mutating func waitForWriteReadiness() async throws(Failure) {
            // Try registering token first (swap to extract)
            var takenRegistering: Token<Registering>? = nil
            swap(&registering, &takenRegistering)

            if let taken = takenRegistering {
                switch await selector.armPreservingToken(consume taken, interest: .write) {
                case .armed(let result):
                    armed = consume result.token
                // Do NOT check error flags here - connect checks SO_ERROR separately
                case .failed(token: let restoredToken, let failure):
                    registering = consume restoredToken
                    throw failure
                }
                return
            }

            // Try armed token (swap to extract)
            var takenArmed: Token<Armed>? = nil
            swap(&armed, &takenArmed)

            if let taken = takenArmed {
                switch await selector.armPreservingToken(consume taken, interest: .write) {
                case .armed(let result):
                    armed = consume result.token
                // Do NOT check error flags here - connect checks SO_ERROR separately
                case .failed(token: let restoredToken, let failure):
                    armed = consume restoredToken
                    throw failure
                }
                return
            }

            preconditionFailure("No token available - concurrent operation or already closed?")
        }

        // MARK: - Half-Close

        /// Shutdown the read direction.
        ///
        /// After this call, reads return 0 (EOF). The kernel may send
        /// a FIN to the peer depending on the socket type.
        ///
        /// This operation is idempotent - calling it multiple times is a no-op.
        ///
        /// - Throws: `Failure` on error.
        public mutating func shutdownRead() async throws(Failure) {
            // Idempotent - no-op if already read-closed
            if await lifecycle.isReadClosed {
                return
            }
            await lifecycle.close.read()

            // Perform syscall, normalize errors for idempotence
            let result = systemShutdown(descriptor, SHUT_RD)
            if result != 0 {
                let err = errno
                // ENOTCONN is OK - socket wasn't connected
                // EINVAL is OK - may already be shut down
                if err != ENOTCONN && err != EINVAL {
                    throw .failure(.platform(errno: err))
                }
            }
        }

        /// Shutdown the write direction.
        ///
        /// After this call, writes throw `.failure(.writeClosed)`.
        /// The kernel sends a FIN to the peer.
        ///
        /// This operation is idempotent - calling it multiple times is a no-op.
        ///
        /// - Throws: `Failure` on error.
        public mutating func shutdownWrite() async throws(Failure) {
            // Idempotent - no-op if already write-closed
            if await lifecycle.isWriteClosed {
                return
            }
            await lifecycle.close.write()

            // Perform syscall, normalize errors for idempotence
            let result = systemShutdown(descriptor, SHUT_WR)
            if result != 0 {
                let err = errno
                // ENOTCONN is OK - socket wasn't connected
                // EINVAL is OK - may already be shut down
                if err != ENOTCONN && err != EINVAL {
                    throw .failure(.platform(errno: err))
                }
            }
        }

        // MARK: - Close

        /// Close the channel and release resources.
        ///
        /// This deregisters from the selector and closes the file descriptor.
        /// After this call, all operations throw `.failure(.closed)`.
        ///
        /// This operation is idempotent - calling it multiple times is a no-op.
        ///
        /// - Throws: `Failure` on error.
        public consuming func close() async throws(Failure) {
            // Transition to closed first - makes operation idempotent
            let alreadyClosed = await lifecycle.close()
            if alreadyClosed {
                return
            }

            // Take whichever token we have (registering or armed)
            var takenRegistering: Token<Registering>? = nil
            swap(&registering, &takenRegistering)

            if let taken = takenRegistering {
                do throws(Failure) {
                    try await selector.deregister(taken)
                } catch {
                    // Deregister failed - best effort: close the fd anyway
                    _ = systemClose(descriptor)
                    throw error
                }
            } else {
                var takenArmed: Token<Armed>? = nil
                swap(&armed, &takenArmed)

                if let taken = takenArmed {
                    do throws(Failure) {
                        try await selector.deregister(taken)
                    } catch {
                        // Deregister failed - best effort: close the fd anyway
                        _ = systemClose(descriptor)
                        throw error
                    }
                }
                // else: No token - channel was closed due to prior error, just close fd
            }

            // Close file descriptor
            let result = systemClose(descriptor)
            if result != 0 {
                let err = errno
                // EBADF means already closed - treat as success
                if err != EBADF {
                    throw .failure(.platform(errno: err))
                }
            }
        }

        // MARK: - Socket Error Handling

        /// Fetch pending socket error via SO_ERROR.
        ///
        /// When kqueue/epoll signals an error flag, the actual error is stored
        /// in SO_ERROR, not in errno. This fetches and clears it.
        ///
        /// - Returns: The pending error code, or nil if no error.
        private func pendingSocketError() -> Int32? {
            var err: Int32 = 0
            var len = socklen_t(MemoryLayout<Int32>.size)
            let rc = getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &err, &len)
            guard rc == 0, err != 0 else { return nil }
            return err
        }
    }
}

// MARK: - Lifecycle Actor

extension IO.Event.Channel {
    /// Actor for half-close state synchronization.
    ///
    /// This actor manages only the lifecycle state transitions.
    /// I/O operations and token management are handled by Channel directly.
    actor Lifecycle {
        private var state: HalfCloseState = .open

        var isReadClosed: Bool {
            switch state {
            case .readClosed, .closed: return true
            case .open, .writeClosed: return false
            }
        }

        var isWriteClosed: Bool {
            switch state {
            case .writeClosed, .closed: return true
            case .open, .readClosed: return false
            }
        }

        var isClosed: Bool {
            state == .closed
        }

        // MARK: - Close Accessor

        /// Accessor for close operations.
        struct Close {
            let lifecycle: Lifecycle

            /// Transition to read-closed state.
            func read() async {
                await lifecycle.closeRead()
            }

            /// Transition to write-closed state.
            func write() async {
                await lifecycle.closeWrite()
            }

            /// Transition to fully closed state.
            /// - Returns: `true` if already closed (no-op), `false` if transition occurred.
            func callAsFunction() async -> Bool {
                await lifecycle.closeAll()
            }
        }

        /// Accessor for close operations.
        nonisolated var close: Close { Close(lifecycle: self) }

        /// Internal: Transition to read-closed state.
        private func closeRead() {
            switch state {
            case .open:
                state = .readClosed
            case .writeClosed:
                state = .closed
            case .readClosed, .closed:
                break  // Already done
            }
        }

        /// Internal: Transition to write-closed state.
        private func closeWrite() {
            switch state {
            case .open:
                state = .writeClosed
            case .readClosed:
                state = .closed
            case .writeClosed, .closed:
                break  // Already done
            }
        }

        /// Internal: Transition to fully closed state.
        /// - Returns: `true` if already closed (no-op), `false` if transition occurred.
        private func closeAll() -> Bool {
            if state == .closed {
                return true
            }
            state = .closed
            return false
        }
    }
}

// MARK: - Half-Close State

extension IO.Event.Channel {
    /// Half-close state of a channel.
    ///
    /// Tracks which directions of the channel are open for I/O.
    enum HalfCloseState: Sendable {
        /// Both directions open.
        case open
        /// Read direction closed (EOF received or shutdownRead called).
        case readClosed
        /// Write direction closed (shutdownWrite called).
        case writeClosed
        /// Both directions closed.
        case closed
    }
}

// MARK: - Internal Result Types

extension IO.Event.Channel {
    /// Result of a read syscall.
    private enum ReadResult {
        case read(Int)
        case eof
        case wouldBlock
        case error(Int32)
    }

    /// Result of a write syscall.
    private enum WriteResult {
        case wrote(Int)
        case wouldBlock
        case error(Int32)
    }
}

// MARK: - Platform Syscall Shims
// Moved to IO.Event.Syscalls.swift for centralized platform abstraction.
// Local aliases for backwards compatibility within this file.

private func systemRead(_ fd: Int32, _ buf: UnsafeMutableRawPointer?, _ count: Int) -> Int {
    IO.Event.Syscalls.read(fd, buf, count)
}

private func systemWrite(_ fd: Int32, _ buf: UnsafeRawPointer?, _ count: Int) -> Int {
    IO.Event.Syscalls.write(fd, buf, count)
}

private func systemShutdown(_ fd: Int32, _ how: Int32) -> Int32 {
    IO.Event.Syscalls.shutdown(fd, how)
}

private func systemClose(_ fd: Int32) -> Int32 {
    IO.Event.Syscalls.close(fd)
}
