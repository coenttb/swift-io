//
//  IO.NonBlocking.Channel.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 29/12/2025.
//

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public import IO_Primitives

extension IO.NonBlocking {
    /// A non-blocking I/O channel for reading and writing bytes.
    ///
    /// Channel provides the user-facing API for non-blocking I/O operations.
    /// It wraps a file descriptor registered with a `Selector` and handles:
    /// - Async read/write with automatic retry on `EAGAIN`/`EWOULDBLOCK`
    /// - Half-close state tracking
    /// - Cancellation via Swift's structured concurrency
    ///
    /// ## Serialization (v1 Constraint)
    ///
    /// **This version serializes all operations.** Channel is `~Copyable` (move-only),
    /// ensuring single ownership. Concurrent `read()` and `write()` calls from different
    /// tasks are not supported in v1. Future versions may support full-duplex I/O.
    ///
    /// ## Usage
    /// ```swift
    /// let channel = try await Channel.wrap(fd, selector: selector, interest: .read)
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

        /// Token for arming (Optional to allow consumption across await).
        /// Access must be serialized by caller (v1 constraint).
        private var token: Token<Armed>?

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
            // Convert registering token to armed token for the state
            self.token = Token(id: id)
        }

        /// Wrap an existing file descriptor in a Channel.
        ///
        /// The descriptor must already be set to non-blocking mode.
        /// The Channel takes ownership and will close it on `close()`.
        ///
        /// - Parameters:
        ///   - descriptor: The file descriptor to wrap.
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
        public mutating func read<B: IO.ContiguousMutableBuffer>(
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
                    let n = Darwin.read(descriptor, ptr.baseAddress, ptr.count)
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
                    await lifecycle.transitionToReadClosed()
                    return 0

                case .wouldBlock:
                    // Take token for arm call (swap with nil to avoid partial consumption)
                    var takenToken: Token<Armed>? = nil
                    swap(&token, &takenToken)
                    guard let actualToken = takenToken else {
                        preconditionFailure("Token not available - concurrent operation?")
                    }

                    // Wait for read readiness
                    let armResult = try await selector.arm(actualToken, interest: .read)
                    token = consume armResult.token

                    // Check for error flags - fetch real socket error via SO_ERROR
                    if armResult.event.flags.contains(.error) {
                        if let err = pendingSocketError() {
                            throw .failure(.platform(errno: err))
                        }
                        // SO_ERROR == 0, fall through and retry syscall
                    }
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
        public mutating func write<B: IO.ContiguousBuffer>(
            _ buffer: B
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
                    let n = Darwin.write(descriptor, ptr.baseAddress, ptr.count)
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
                    // Take token for arm call (swap with nil to avoid partial consumption)
                    var takenToken: Token<Armed>? = nil
                    swap(&token, &takenToken)
                    guard let actualToken = takenToken else {
                        preconditionFailure("Token not available - concurrent operation?")
                    }

                    // Wait for write readiness
                    let armResult = try await selector.arm(actualToken, interest: .write)
                    token = consume armResult.token

                    // Check for error flags - fetch real socket error via SO_ERROR
                    if armResult.event.flags.contains(.error) {
                        if let err = pendingSocketError() {
                            throw .failure(.platform(errno: err))
                        }
                        // SO_ERROR == 0, fall through and retry syscall
                    }
                    // Continue loop to retry write

                case .error(let err):
                    throw .failure(.platform(errno: err))
                }
            }
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
            await lifecycle.transitionToReadClosed()

            // Perform syscall, normalize errors for idempotence
            let result = Darwin.shutdown(descriptor, SHUT_RD)
            if result != 0 {
                let err = errno
                // ENOTCONN is OK - socket wasn't connected
                // EINVAL is OK - may already be shut down
                // ENOTSOCK is OK - not a socket (e.g., pipe)
                if err != ENOTCONN && err != EINVAL && err != ENOTSOCK {
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
            await lifecycle.transitionToWriteClosed()

            // Perform syscall, normalize errors for idempotence
            let result = Darwin.shutdown(descriptor, SHUT_WR)
            if result != 0 {
                let err = errno
                // ENOTCONN is OK - socket wasn't connected
                // EINVAL is OK - may already be shut down
                // ENOTSOCK is OK - not a socket (e.g., pipe)
                if err != ENOTCONN && err != EINVAL && err != ENOTSOCK {
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
            let alreadyClosed = await lifecycle.transitionToClosed()
            if alreadyClosed {
                return
            }

            // Take token for deregister (swap with nil to avoid partial consumption)
            var takenToken: Token<Armed>? = nil
            swap(&token, &takenToken)
            guard let actualToken = takenToken else {
                preconditionFailure("Token not available")
            }

            // Deregister from selector
            try await selector.deregister(actualToken)

            // Close file descriptor
            let result = Darwin.close(descriptor)
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

extension IO.NonBlocking.Channel {
    /// Actor for half-close state synchronization.
    ///
    /// This actor manages only the lifecycle state transitions.
    /// I/O operations and token management are handled by Channel directly.
    actor Lifecycle: Sendable {
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

        func transitionToReadClosed() {
            switch state {
            case .open:
                state = .readClosed
            case .writeClosed:
                state = .closed
            case .readClosed, .closed:
                break  // Already done
            }
        }

        func transitionToWriteClosed() {
            switch state {
            case .open:
                state = .writeClosed
            case .readClosed:
                state = .closed
            case .writeClosed, .closed:
                break  // Already done
            }
        }

        /// Transition to closed state.
        /// - Returns: `true` if already closed (no-op), `false` if transition occurred.
        func transitionToClosed() -> Bool {
            if state == .closed {
                return true
            }
            state = .closed
            return false
        }
    }
}

// MARK: - Half-Close State

extension IO.NonBlocking.Channel {
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

extension IO.NonBlocking.Channel {
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
