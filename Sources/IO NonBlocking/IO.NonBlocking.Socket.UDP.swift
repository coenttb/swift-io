//
//  IO.NonBlocking.Socket.UDP.swift
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
    /// A UDP datagram socket.
    ///
    /// UDP sockets provide connectionless, unreliable datagram communication.
    /// Each `sendto` and `recvfrom` operates on discrete messages.
    ///
    /// ## Usage
    /// ```swift
    /// // Server: bind to receive datagrams
    /// var udp = try await Socket.UDP.bind(
    ///     to: .ipv4Any(port: 8080),
    ///     on: selector
    /// )
    /// defer { try? await udp.close() }
    ///
    /// var buffer = [UInt8](repeating: 0, count: 1024)
    /// let (bytesRead, sender) = try await udp.recvfrom(into: &buffer)
    /// try await udp.sendto(buffer[..<bytesRead], to: sender)
    /// ```
    ///
    /// ## Ownership
    /// UDP is `~Copyable` (move-only). The socket is automatically closed
    /// when the UDP instance is consumed or goes out of scope.
    public struct UDP: ~Copyable, Sendable {
        /// The selector.
        @usableFromInline
        let selector: IO.NonBlocking.Selector

        /// The socket file descriptor.
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

        /// The local address this socket is bound to (if any).
        public let localAddress: Address?

        /// Whether this socket is connected to a default destination.
        @usableFromInline
        var _connectedAddress: Address?

        /// Private initializer.
        @usableFromInline
        init(
            selector: IO.NonBlocking.Selector,
            descriptor: Int32,
            id: IO.NonBlocking.ID,
            token: consuming IO.NonBlocking.Token<IO.NonBlocking.Registering>,
            localAddress: Address?
        ) {
            self.selector = selector
            self.descriptor = descriptor
            self.id = id
            self.registering = consume token
            self.armed = nil
            self.localAddress = localAddress
            self._connectedAddress = nil
        }
    }
}

// MARK: - Creation

extension IO.NonBlocking.Socket.UDP {
    /// Bind to a local address for receiving datagrams.
    ///
    /// Creates a UDP socket bound to the specified address.
    ///
    /// - Parameters:
    ///   - address: The local address to bind to.
    ///   - selector: The selector to register with.
    ///   - reuseAddress: Whether to enable SO_REUSEADDR (default: true).
    /// - Returns: A bound UDP socket.
    /// - Throws: `Failure` on bind error.
    public static func bind(
        to address: IO.NonBlocking.Socket.Address,
        on selector: IO.NonBlocking.Selector,
        reuseAddress: Bool = true
    ) async throws(IO.NonBlocking.Failure) -> Self {
        // Create socket
        let fd = socket(address.family, SOCK_DGRAM, 0)
        guard fd >= 0 else {
            throw .failure(.platform(errno: errno))
        }

        // Set socket options
        do throws(IO.NonBlocking.Failure) {
            if reuseAddress {
                try IO.NonBlocking.Socket.Listener.setReuseAddress(fd)
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

        // Get the actual bound address (port may have been 0)
        let boundAddress: IO.NonBlocking.Socket.Address
        do throws(IO.NonBlocking.Failure) {
            boundAddress = try IO.NonBlocking.Socket.Listener.getBoundAddress(fd) ?? address
        } catch {
            _ = IO.NonBlocking.Socket.TCP.systemClose(fd)
            throw error
        }

        // Register with selector
        let regResult = try await selector.register(fd, interest: [.read, .write])

        return Self(
            selector: selector,
            descriptor: fd,
            id: regResult.id,
            token: regResult.token,
            localAddress: boundAddress
        )
    }

    /// Create an unbound IPv4 UDP socket for sending.
    ///
    /// Creates a UDP socket that can send datagrams without binding.
    /// The OS will assign an ephemeral port on first send.
    ///
    /// - Parameter selector: The selector to register with.
    /// - Returns: An unbound UDP socket.
    /// - Throws: `Failure` on creation error.
    public static func unboundIPv4(
        on selector: IO.NonBlocking.Selector
    ) async throws(IO.NonBlocking.Failure) -> Self {
        try await createUnbound(family: AF_INET, on: selector)
    }

    /// Create an unbound IPv6 UDP socket for sending.
    ///
    /// Creates a UDP socket that can send datagrams without binding.
    /// The OS will assign an ephemeral port on first send.
    ///
    /// - Parameter selector: The selector to register with.
    /// - Returns: An unbound UDP socket.
    /// - Throws: `Failure` on creation error.
    public static func unboundIPv6(
        on selector: IO.NonBlocking.Selector
    ) async throws(IO.NonBlocking.Failure) -> Self {
        try await createUnbound(family: AF_INET6, on: selector)
    }

    /// Internal helper to create an unbound socket.
    private static func createUnbound(
        family: Int32,
        on selector: IO.NonBlocking.Selector
    ) async throws(IO.NonBlocking.Failure) -> Self {
        // Create socket
        let fd = socket(family, SOCK_DGRAM, 0)
        guard fd >= 0 else {
            throw .failure(.platform(errno: errno))
        }

        // Set non-blocking
        do throws(IO.NonBlocking.Failure) {
            try IO.NonBlocking.Socket.TCP.setNonBlocking(fd)
        } catch {
            _ = IO.NonBlocking.Socket.TCP.systemClose(fd)
            throw error
        }

        // Register with selector
        let regResult = try await selector.register(fd, interest: [.read, .write])

        return Self(
            selector: selector,
            descriptor: fd,
            id: regResult.id,
            token: regResult.token,
            localAddress: nil
        )
    }
}

// MARK: - Send/Receive

extension IO.NonBlocking.Socket.UDP {
    /// Send a datagram to a specific address.
    ///
    /// - Parameters:
    ///   - buffer: The data to send.
    ///   - address: The destination address.
    /// - Returns: The number of bytes sent.
    /// - Throws: `Failure` on error.
    public mutating func sendto<B: IO.ContiguousBuffer>(
        _ buffer: B,
        to address: IO.NonBlocking.Socket.Address
    ) async throws(IO.NonBlocking.Failure) -> Int {
        while true {
            let result = buffer.withUnsafeBytes { ptr -> SendResult in
                address.withSockAddr { addr, addrLen in
                    #if canImport(Darwin)
                    let n = Darwin.sendto(descriptor, ptr.baseAddress, ptr.count, 0, addr, addrLen)
                    #else
                    let n = Glibc.sendto(descriptor, ptr.baseAddress, ptr.count, 0, addr, addrLen)
                    #endif
                    if n >= 0 {
                        return .sent(n)
                    } else {
                        let err = errno
                        if err == EAGAIN || err == EWOULDBLOCK {
                            return .wouldBlock
                        } else {
                            return .error(err)
                        }
                    }
                }
            }

            switch result {
            case .sent(let n):
                return n
            case .wouldBlock:
                try await armForWrite()
            case .error(let err):
                throw .failure(.platform(errno: err))
            }
        }
    }

    /// Receive a datagram and get the sender's address.
    ///
    /// - Parameter buffer: The buffer to receive into.
    /// - Returns: A tuple of (bytes received, sender address).
    /// - Throws: `Failure` on error.
    public mutating func recvfrom<B: IO.ContiguousMutableBuffer>(
        into buffer: inout B
    ) async throws(IO.NonBlocking.Failure) -> (Int, IO.NonBlocking.Socket.Address) {
        while true {
            var senderStorage = sockaddr_storage()
            var senderLen = socklen_t(MemoryLayout<sockaddr_storage>.size)

            let result = buffer.withUnsafeMutableBytes { ptr -> RecvResult in
                withUnsafeMutablePointer(to: &senderStorage) { storagePtr in
                    storagePtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                        #if canImport(Darwin)
                        let n = Darwin.recvfrom(descriptor, ptr.baseAddress, ptr.count, 0, sockPtr, &senderLen)
                        #else
                        let n = Glibc.recvfrom(descriptor, ptr.baseAddress, ptr.count, 0, sockPtr, &senderLen)
                        #endif
                        if n >= 0 {
                            return .received(n)
                        } else {
                            let err = errno
                            if err == EAGAIN || err == EWOULDBLOCK {
                                return .wouldBlock
                            } else {
                                return .error(err)
                            }
                        }
                    }
                }
            }

            switch result {
            case .received(let n):
                // Parse sender address
                let senderAddress = withUnsafePointer(to: &senderStorage) { ptr in
                    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                        IO.NonBlocking.Socket.Address.from(sockaddr: sockPtr, length: senderLen)
                    }
                } ?? IO.NonBlocking.Socket.Address.ipv4(0, 0, 0, 0, port: 0)

                return (n, senderAddress)

            case .wouldBlock:
                try await armForRead()

            case .error(let err):
                throw .failure(.platform(errno: err))
            }
        }
    }

    /// Result of a send syscall.
    private enum SendResult {
        case sent(Int)
        case wouldBlock
        case error(Int32)
    }

    /// Result of a recv syscall.
    private enum RecvResult {
        case received(Int)
        case wouldBlock
        case error(Int32)
    }
}

// MARK: - Connected Mode

extension IO.NonBlocking.Socket.UDP {
    /// The connected address (if any).
    public var connectedAddress: IO.NonBlocking.Socket.Address? {
        _connectedAddress
    }

    /// Connect to a default destination.
    ///
    /// After connecting, you can use `send()` and `recv()` instead of
    /// `sendto()` and `recvfrom()`. The socket will only receive datagrams
    /// from the connected address.
    ///
    /// - Parameter address: The destination address.
    /// - Throws: `Failure` on error.
    public mutating func connect(
        to address: IO.NonBlocking.Socket.Address
    ) throws(IO.NonBlocking.Failure) {
        let result = address.withSockAddr { addr, len in
            #if canImport(Darwin)
            Darwin.connect(descriptor, addr, len)
            #else
            Glibc.connect(descriptor, addr, len)
            #endif
        }

        if result < 0 {
            throw .failure(.platform(errno: errno))
        }

        _connectedAddress = address
    }

    /// Send a datagram to the connected address.
    ///
    /// Requires a prior call to `connect(to:)`.
    ///
    /// - Parameter buffer: The data to send.
    /// - Returns: The number of bytes sent.
    /// - Throws: `Failure` on error.
    public mutating func send<B: IO.ContiguousBuffer>(
        _ buffer: B
    ) async throws(IO.NonBlocking.Failure) -> Int {
        guard _connectedAddress != nil else {
            throw .failure(.notConnected)
        }

        while true {
            let result = buffer.withUnsafeBytes { ptr -> SendResult in
                #if canImport(Darwin)
                let n = Darwin.send(descriptor, ptr.baseAddress, ptr.count, 0)
                #else
                let n = Glibc.send(descriptor, ptr.baseAddress, ptr.count, 0)
                #endif
                if n >= 0 {
                    return .sent(n)
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
            case .sent(let n):
                return n
            case .wouldBlock:
                try await armForWrite()
            case .error(let err):
                throw .failure(.platform(errno: err))
            }
        }
    }

    /// Receive a datagram from the connected address.
    ///
    /// Requires a prior call to `connect(to:)`.
    ///
    /// - Parameter buffer: The buffer to receive into.
    /// - Returns: The number of bytes received.
    /// - Throws: `Failure` on error.
    public mutating func recv<B: IO.ContiguousMutableBuffer>(
        into buffer: inout B
    ) async throws(IO.NonBlocking.Failure) -> Int {
        guard _connectedAddress != nil else {
            throw .failure(.notConnected)
        }

        while true {
            let result = buffer.withUnsafeMutableBytes { ptr -> RecvResult in
                #if canImport(Darwin)
                let n = Darwin.recv(descriptor, ptr.baseAddress, ptr.count, 0)
                #else
                let n = Glibc.recv(descriptor, ptr.baseAddress, ptr.count, 0)
                #endif
                if n >= 0 {
                    return .received(n)
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
            case .received(let n):
                return n
            case .wouldBlock:
                try await armForRead()
            case .error(let err):
                throw .failure(.platform(errno: err))
            }
        }
    }
}

// MARK: - Arming Helpers

extension IO.NonBlocking.Socket.UDP {
    /// Arm for read readiness.
    private mutating func armForRead() async throws(IO.NonBlocking.Failure) {
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

    /// Arm for write readiness.
    private mutating func armForWrite() async throws(IO.NonBlocking.Failure) {
        var takenRegistering: IO.NonBlocking.Token<IO.NonBlocking.Registering>? = nil
        swap(&registering, &takenRegistering)

        if let taken = takenRegistering {
            switch await selector.armPreservingToken(consume taken, interest: .write) {
            case .armed(let result):
                armed = consume result.token
            case .failed(token: let restoredToken, failure: let failure):
                registering = consume restoredToken
                throw failure
            }
            return
        }

        var takenArmed: IO.NonBlocking.Token<IO.NonBlocking.Armed>? = nil
        swap(&armed, &takenArmed)

        if let taken = takenArmed {
            switch await selector.armPreservingToken(consume taken, interest: .write) {
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
}

// MARK: - Close

extension IO.NonBlocking.Socket.UDP {
    /// Close the socket.
    public consuming func close() async throws(IO.NonBlocking.Failure) {
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
