//
//  IO.NonBlocking.Socket.TCP.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 29/12/2025.
//

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

extension IO.NonBlocking.Socket {
    /// A connected TCP socket.
    ///
    /// TCP sockets provide reliable, ordered, connection-oriented byte streams.
    /// Use `connect(to:on:)` to establish a connection to a remote server.
    ///
    /// ## Usage
    /// ```swift
    /// let tcp = try await Socket.TCP.connect(
    ///     to: .ipv4(127, 0, 0, 1, port: 8080),
    ///     on: selector
    /// )
    /// defer { try? await tcp.close() }
    ///
    /// var buffer = [UInt8](repeating: 0, count: 1024)
    /// let bytesRead = try await tcp.read(into: &buffer)
    /// ```
    ///
    /// ## Ownership
    /// TCP is `~Copyable` (move-only). The socket is automatically closed
    /// when the TCP instance is consumed or goes out of scope.
    public struct TCP: ~Copyable, Sendable {
        /// The underlying channel.
        @usableFromInline
        var _channel: IO.NonBlocking.Channel

        /// The local address (lazily cached).
        private var _localAddress: Address?

        /// The remote address.
        public let remoteAddress: Address

        /// Private initializer.
        @usableFromInline
        init(channel: consuming IO.NonBlocking.Channel, remoteAddress: Address) {
            self._channel = channel
            self.remoteAddress = remoteAddress
            self._localAddress = nil
        }
    }
}

// MARK: - Connect

extension IO.NonBlocking.Socket.TCP {
    /// Connect to a remote TCP endpoint.
    ///
    /// Establishes a TCP connection to the specified address. The connection
    /// is performed asynchronously using non-blocking I/O.
    ///
    /// - Parameters:
    ///   - address: The remote address to connect to.
    ///   - selector: The selector to register with.
    /// - Returns: A connected TCP socket.
    /// - Throws: `Failure` on connection error.
    ///
    /// ## Connection Process
    /// 1. Create socket with appropriate family (IPv4/IPv6)
    /// 2. Set non-blocking mode
    /// 3. Initiate connection (returns immediately with EINPROGRESS)
    /// 4. Wait for write readiness (connection complete)
    /// 5. Check for socket error
    ///
    /// ## Cancellation
    /// If cancelled during connection, the socket is closed and resources released.
    public static func connect(
        to address: IO.NonBlocking.Socket.Address,
        on selector: IO.NonBlocking.Selector
    ) async throws(IO.NonBlocking.Failure) -> Self {
        // Create socket
        let fd = socket(address.family, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw .failure(.platform(errno: errno))
        }

        // Set non-blocking
        do throws(IO.NonBlocking.Failure) {
            try setNonBlocking(fd)
        } catch {
            _ = systemClose(fd)
            throw error
        }

        // Initiate connection
        let connectResult = address.withSockAddr { addr, len in
            #if canImport(Darwin)
            Darwin.connect(fd, addr, len)
            #else
            Glibc.connect(fd, addr, len)
            #endif
        }

        if connectResult < 0 {
            let err = errno
            if err != EINPROGRESS {
                _ = systemClose(fd)
                throw .failure(.platform(errno: err))
            }
            // EINPROGRESS is expected for non-blocking connect
        }

        // Register with selector and wait for write readiness
        var channel: IO.NonBlocking.Channel
        do throws(IO.NonBlocking.Failure) {
            channel = try await IO.NonBlocking.Channel.wrap(
                fd,
                selector: selector,
                interest: .write
            )
        } catch {
            _ = systemClose(fd)
            throw error
        }

        // Check SO_ERROR to verify connection succeeded
        let socketError = pendingSocketError(fd)
        if let err = socketError {
            try? await channel.close()
            throw .failure(.platform(errno: err))
        }

        return Self(channel: consume channel, remoteAddress: address)
    }

    /// Platform-agnostic close syscall.
    @usableFromInline
    static func systemClose(_ fd: Int32) -> Int32 {
        #if canImport(Darwin)
        Darwin.close(fd)
        #else
        Glibc.close(fd)
        #endif
    }

    /// Set a file descriptor to non-blocking mode.
    @usableFromInline
    static func setNonBlocking(_ fd: Int32) throws(IO.NonBlocking.Failure) {
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0 else {
            throw .failure(.platform(errno: errno))
        }
        let result = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        guard result >= 0 else {
            throw .failure(.platform(errno: errno))
        }
    }

    /// Fetch pending socket error via SO_ERROR.
    @usableFromInline
    static func pendingSocketError(_ fd: Int32) -> Int32? {
        var err: Int32 = 0
        var len = socklen_t(MemoryLayout<Int32>.size)
        let rc = getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len)
        guard rc == 0, err != 0 else { return nil }
        return err
    }
}

// MARK: - I/O Operations

extension IO.NonBlocking.Socket.TCP {
    /// Read bytes into a buffer.
    ///
    /// - Parameter buffer: The buffer to read into.
    /// - Returns: The number of bytes read, or 0 on EOF.
    /// - Throws: `Failure` on error.
    @inlinable
    public mutating func read<B: IO.ContiguousMutableBuffer>(
        into buffer: inout B
    ) async throws(IO.NonBlocking.Failure) -> Int {
        try await _channel.read(into: &buffer)
    }

    /// Write bytes from a buffer.
    ///
    /// - Parameter buffer: The buffer to write from.
    /// - Returns: The number of bytes written.
    /// - Throws: `Failure` on error.
    @inlinable
    public mutating func write<B: IO.ContiguousBuffer>(
        _ buffer: B
    ) async throws(IO.NonBlocking.Failure) -> Int {
        try await _channel.write(buffer)
    }

    /// Shutdown the read direction.
    @inlinable
    public mutating func shutdownRead() async throws(IO.NonBlocking.Failure) {
        try await _channel.shutdownRead()
    }

    /// Shutdown the write direction.
    @inlinable
    public mutating func shutdownWrite() async throws(IO.NonBlocking.Failure) {
        try await _channel.shutdownWrite()
    }

    /// Close the socket.
    @inlinable
    public consuming func close() async throws(IO.NonBlocking.Failure) {
        try await _channel.close()
    }
}

// MARK: - Properties

extension IO.NonBlocking.Socket.TCP {
    /// The underlying channel for advanced operations.
    ///
    /// Use this for direct channel access when needed. Most users should
    /// use the TCP-level read/write methods instead.
    @inlinable
    public var channel: IO.NonBlocking.Channel {
        _read { yield _channel }
        _modify { yield &_channel }
    }
}
