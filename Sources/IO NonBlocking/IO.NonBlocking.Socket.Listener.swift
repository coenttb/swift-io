//
//  IO.NonBlocking.Socket.Listener.swift
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
    /// A TCP listening socket.
    ///
    /// Listens for incoming TCP connections on a local address.
    /// Use `bind(to:on:)` to create a listener and `accept()` to accept connections.
    ///
    /// ## Usage
    /// ```swift
    /// let listener = try await Socket.Listener.bind(
    ///     to: .ipv4Any(port: 8080),
    ///     on: selector
    /// )
    /// defer { try? await listener.close() }
    ///
    /// while true {
    ///     let client = try await listener.accept()
    ///     // Handle client connection...
    /// }
    /// ```
    ///
    /// ## Ownership
    /// Listener is `~Copyable` (move-only). The socket is automatically closed
    /// when the Listener instance is consumed or goes out of scope.
    public struct Listener: ~Copyable, Sendable {
        /// The selector.
        @usableFromInline
        let selector: IO.NonBlocking.Selector

        /// The listening socket file descriptor.
        @usableFromInline
        let descriptor: Int32

        /// The registration ID.
        @usableFromInline
        let id: IO.NonBlocking.ID

        /// Token state.
        @usableFromInline
        var registering: IO.NonBlocking.Token<IO.NonBlocking.Registering>?

        @usableFromInline
        var armed: IO.NonBlocking.Token<IO.NonBlocking.Armed>?

        /// The local address this listener is bound to.
        public let localAddress: Address

        /// Private initializer.
        @usableFromInline
        init(
            selector: IO.NonBlocking.Selector,
            descriptor: Int32,
            id: IO.NonBlocking.ID,
            token: consuming IO.NonBlocking.Token<IO.NonBlocking.Registering>,
            localAddress: Address
        ) {
            self.selector = selector
            self.descriptor = descriptor
            self.id = id
            self.registering = consume token
            self.armed = nil
            self.localAddress = localAddress
        }
    }
}

// MARK: - Bind

extension IO.NonBlocking.Socket.Listener {
    /// The default listen backlog size.
    public static let defaultBacklog: Int32 = 128

    /// Bind to a local address and start listening.
    ///
    /// Creates a listening socket bound to the specified address.
    ///
    /// - Parameters:
    ///   - address: The local address to bind to.
    ///   - selector: The selector to register with.
    ///   - backlog: Maximum length of the pending connection queue.
    ///   - reuseAddress: Whether to enable SO_REUSEADDR (default: true).
    /// - Returns: A listening socket.
    /// - Throws: `Failure` on bind or listen error.
    public static func bind(
        to address: IO.NonBlocking.Socket.Address,
        on selector: IO.NonBlocking.Selector,
        backlog: Int32 = defaultBacklog,
        reuseAddress: Bool = true
    ) async throws(IO.NonBlocking.Failure) -> Self {
        // Create socket
        let fd = socket(address.family, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw .failure(.platform(errno: errno))
        }

        // Set socket options
        do throws(IO.NonBlocking.Failure) {
            if reuseAddress {
                try setReuseAddress(fd)
            }
            try IO.NonBlocking.Socket.TCP.setNonBlocking(fd)
        } catch {
            _ = IO.NonBlocking.Socket.TCP.systemClose(fd)
            throw error
        }

        // Bind to address
        let bindResult = address.withSockAddr { addr, len in
            #if canImport(Darwin)
            Darwin.bind(fd, addr, len)
            #else
            Glibc.bind(fd, addr, len)
            #endif
        }
        if bindResult < 0 {
            let err = errno
            _ = IO.NonBlocking.Socket.TCP.systemClose(fd)
            throw .failure(.platform(errno: err))
        }

        // Start listening
        #if canImport(Darwin)
        let listenResult = Darwin.listen(fd, backlog)
        #else
        let listenResult = Glibc.listen(fd, backlog)
        #endif
        if listenResult < 0 {
            let err = errno
            _ = IO.NonBlocking.Socket.TCP.systemClose(fd)
            throw .failure(.platform(errno: err))
        }

        // Get the actual bound address (port may have been 0)
        let boundAddress: IO.NonBlocking.Socket.Address
        do throws(IO.NonBlocking.Failure) {
            boundAddress = try getBoundAddress(fd) ?? address
        } catch {
            _ = IO.NonBlocking.Socket.TCP.systemClose(fd)
            throw error
        }

        // Register with selector
        let regResult = try await selector.register(fd, interest: .read)

        return Self(
            selector: selector,
            descriptor: fd,
            id: regResult.id,
            token: regResult.token,
            localAddress: boundAddress
        )
    }

    /// Set SO_REUSEADDR on a socket.
    @usableFromInline
    static func setReuseAddress(_ fd: Int32) throws(IO.NonBlocking.Failure) {
        var value: Int32 = 1
        let result = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &value, socklen_t(MemoryLayout<Int32>.size))
        guard result >= 0 else {
            throw .failure(.platform(errno: errno))
        }
    }

    /// Get the bound address of a socket.
    @usableFromInline
    static func getBoundAddress(_ fd: Int32) throws(IO.NonBlocking.Failure) -> IO.NonBlocking.Socket.Address? {
        var storage = sockaddr_storage()
        var length = socklen_t(MemoryLayout<sockaddr_storage>.size)

        let result = withUnsafeMutablePointer(to: &storage) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                getsockname(fd, sockPtr, &length)
            }
        }

        guard result >= 0 else {
            throw .failure(.platform(errno: errno))
        }

        return withUnsafePointer(to: &storage) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                IO.NonBlocking.Socket.Address.from(sockaddr: sockPtr, length: length)
            }
        }
    }
}

// MARK: - Accept

extension IO.NonBlocking.Socket.Listener {
    /// Accept an incoming connection.
    ///
    /// Waits for an incoming connection and returns a connected TCP socket.
    ///
    /// - Returns: A connected TCP socket.
    /// - Throws: `Failure` on accept error.
    ///
    /// ## Non-blocking Behavior
    /// This method waits asynchronously for a connection to arrive.
    /// It uses the selector's readiness notification to avoid busy-waiting.
    public mutating func accept() async throws(IO.NonBlocking.Failure) -> IO.NonBlocking.Socket.TCP {
        while true {
            // Try to accept
            var clientAddr = sockaddr_storage()
            var clientLen = socklen_t(MemoryLayout<sockaddr_storage>.size)

            let clientFd = withUnsafeMutablePointer(to: &clientAddr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                    #if canImport(Darwin)
                    Darwin.accept(descriptor, sockPtr, &clientLen)
                    #else
                    Glibc.accept(descriptor, sockPtr, &clientLen)
                    #endif
                }
            }

            if clientFd >= 0 {
                // Success - set non-blocking and wrap in TCP
                do throws(IO.NonBlocking.Failure) {
                    try IO.NonBlocking.Socket.TCP.setNonBlocking(clientFd)
                } catch {
                    _ = IO.NonBlocking.Socket.TCP.systemClose(clientFd)
                    throw error
                }

                // Get remote address
                let remoteAddress = withUnsafePointer(to: &clientAddr) { ptr in
                    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                        IO.NonBlocking.Socket.Address.from(sockaddr: sockPtr, length: clientLen)
                    }
                } ?? IO.NonBlocking.Socket.Address.ipv4(0, 0, 0, 0, port: 0)

                // Wrap in channel
                let channel: IO.NonBlocking.Channel
                do throws(IO.NonBlocking.Failure) {
                    channel = try await IO.NonBlocking.Channel.wrap(
                        clientFd,
                        selector: selector,
                        interest: [.read, .write]
                    )
                } catch {
                    _ = IO.NonBlocking.Socket.TCP.systemClose(clientFd)
                    throw error
                }

                return IO.NonBlocking.Socket.TCP(channel: consume channel, remoteAddress: remoteAddress)
            }

            // Check error
            let err = errno
            if err == EAGAIN || err == EWOULDBLOCK {
                // Wait for read readiness (new connection)
                try await armForRead()
                continue
            }

            throw .failure(.platform(errno: err))
        }
    }

    /// Arm for read readiness.
    private mutating func armForRead() async throws(IO.NonBlocking.Failure) {
        // Try registering token first
        var takenRegistering: IO.NonBlocking.Token<IO.NonBlocking.Registering>? = nil
        swap(&registering, &takenRegistering)

        if let taken = takenRegistering {
            switch await selector.armPreservingToken(consume taken, interest: .read) {
            case .armed(let result):
                armed = consume result.token
            case .failed(token: let restoredToken, failure: let failure):
                registering = consume restoredToken
                throw failure
            }
            return
        }

        // Try armed token
        var takenArmed: IO.NonBlocking.Token<IO.NonBlocking.Armed>? = nil
        swap(&armed, &takenArmed)

        if let taken = takenArmed {
            switch await selector.armPreservingToken(consume taken, interest: .read) {
            case .armed(let result):
                armed = consume result.token
            case .failed(token: let restoredToken, failure: let failure):
                armed = consume restoredToken
                throw failure
            }
            return
        }

        preconditionFailure("No token available")
    }

    /// Close the listener.
    public consuming func close() async throws(IO.NonBlocking.Failure) {
        // Take whichever token we have
        var takenRegistering: IO.NonBlocking.Token<IO.NonBlocking.Registering>? = nil
        swap(&registering, &takenRegistering)

        if let taken = takenRegistering {
            do throws(IO.NonBlocking.Failure) {
                try await selector.deregister(taken)
            } catch {
                _ = IO.NonBlocking.Socket.TCP.systemClose(descriptor)
                throw error
            }
        } else {
            var takenArmed: IO.NonBlocking.Token<IO.NonBlocking.Armed>? = nil
            swap(&armed, &takenArmed)

            if let taken = takenArmed {
                do throws(IO.NonBlocking.Failure) {
                    try await selector.deregister(taken)
                } catch {
                    _ = IO.NonBlocking.Socket.TCP.systemClose(descriptor)
                    throw error
                }
            }
        }

        let result = IO.NonBlocking.Socket.TCP.systemClose(descriptor)
        if result != 0 {
            let err = errno
            if err != EBADF {
                throw .failure(.platform(errno: err))
            }
        }
    }
}
