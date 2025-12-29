//
//  IO.NonBlocking.Socket.Address.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 29/12/2025.
//

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public import IPv4_Standard
public import IPv6_Standard

extension IO.NonBlocking.Socket {
    /// A network socket address.
    ///
    /// Supports IPv4, IPv6, and Unix domain socket addresses.
    /// Uses RFC 791 for IPv4 and RFC 4291 for IPv6 address types.
    ///
    /// ## Creation
    /// ```swift
    /// let ipv4 = Address.ipv4(.loopback, port: 8080)
    /// let ipv6 = Address.ipv6(.loopback, port: 8080)
    /// let unix = Address.unix("/tmp/my.sock")
    /// ```
    ///
    /// ## Network Byte Order
    /// IP addresses use standard types that handle byte order internally.
    /// Conversion to sockaddr structures is handled automatically.
    public struct Address: Sendable, Equatable {
        /// The address storage.
        @usableFromInline
        let storage: Storage

        /// Private initializer.
        @usableFromInline
        init(storage: Storage) {
            self.storage = storage
        }
    }
}

// MARK: - Storage

extension IO.NonBlocking.Socket.Address {
    /// Internal storage for address data.
    @usableFromInline
    enum Storage: Sendable, Equatable {
        /// IPv4 address + port.
        case ipv4(address: IPv4.Address, port: UInt16)

        /// IPv6 address + port + flow info + scope ID.
        case ipv6(address: IPv6.Address, port: UInt16, flowInfo: UInt32, scopeId: UInt32)

        /// Unix domain socket path.
        case unix(path: UnixPath)
    }
}

// MARK: - Unix Path Storage

extension IO.NonBlocking.Socket.Address {
    /// Fixed-size storage for Unix domain socket paths.
    ///
    /// Unix socket paths have a platform-dependent maximum length:
    /// - Darwin: 104 bytes (including null terminator)
    /// - Linux: 108 bytes (including null terminator)
    public struct UnixPath: Sendable {
        #if os(Linux)
        /// Maximum path length on Linux (sun_path size).
        public static let maxLength = 108
        #else
        /// Maximum path length on Darwin (sun_path size).
        public static let maxLength = 104
        #endif

        /// Path bytes (null-terminated).
        @usableFromInline
        var bytes: (
            UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
            UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
            UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
            UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
            UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
            UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
            UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
            UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
            UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
            UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
            UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
            UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
            UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
        )

        /// The length of the path (excluding null terminator).
        @usableFromInline
        let length: Int

        /// Creates a Unix path from a StaticString.
        ///
        /// - Parameter path: The path string.
        /// - Returns: `nil` if the path exceeds the maximum length.
        public init?(_ path: StaticString) {
            let len = path.utf8CodeUnitCount
            guard len < Self.maxLength else { return nil }

            self.length = len
            self.bytes = (
                0, 0, 0, 0, 0, 0, 0, 0,
                0, 0, 0, 0, 0, 0, 0, 0,
                0, 0, 0, 0, 0, 0, 0, 0,
                0, 0, 0, 0, 0, 0, 0, 0,
                0, 0, 0, 0, 0, 0, 0, 0,
                0, 0, 0, 0, 0, 0, 0, 0,
                0, 0, 0, 0, 0, 0, 0, 0,
                0, 0, 0, 0, 0, 0, 0, 0,
                0, 0, 0, 0, 0, 0, 0, 0,
                0, 0, 0, 0, 0, 0, 0, 0,
                0, 0, 0, 0, 0, 0, 0, 0,
                0, 0, 0, 0, 0, 0, 0, 0,
                0, 0, 0, 0, 0, 0, 0, 0
            )

            // Copy path bytes
            path.withUTF8Buffer { buffer in
                withUnsafeMutableBytes(of: &self.bytes) { dest in
                    for i in 0..<len {
                        dest[i] = buffer[i]
                    }
                    // Null terminator
                    dest[len] = 0
                }
            }
        }

        /// Creates a Unix path from a buffer of bytes.
        ///
        /// - Parameter buffer: The path bytes (must be null-terminated or within maxLength).
        /// - Returns: `nil` if the path exceeds the maximum length.
        public init?(bytes buffer: UnsafeBufferPointer<UInt8>) {
            // Find null terminator or use buffer count
            var len = 0
            for i in 0..<min(buffer.count, Self.maxLength) {
                if buffer[i] == 0 {
                    break
                }
                len = i + 1
            }
            guard len < Self.maxLength else { return nil }

            self.length = len
            self.bytes = (
                0, 0, 0, 0, 0, 0, 0, 0,
                0, 0, 0, 0, 0, 0, 0, 0,
                0, 0, 0, 0, 0, 0, 0, 0,
                0, 0, 0, 0, 0, 0, 0, 0,
                0, 0, 0, 0, 0, 0, 0, 0,
                0, 0, 0, 0, 0, 0, 0, 0,
                0, 0, 0, 0, 0, 0, 0, 0,
                0, 0, 0, 0, 0, 0, 0, 0,
                0, 0, 0, 0, 0, 0, 0, 0,
                0, 0, 0, 0, 0, 0, 0, 0,
                0, 0, 0, 0, 0, 0, 0, 0,
                0, 0, 0, 0, 0, 0, 0, 0,
                0, 0, 0, 0, 0, 0, 0, 0
            )

            // Copy path bytes
            withUnsafeMutableBytes(of: &self.bytes) { dest in
                for i in 0..<len {
                    dest[i] = buffer[i]
                }
                // Null terminator
                dest[len] = 0
            }
        }
    }
}

// MARK: - UnixPath Equatable

extension IO.NonBlocking.Socket.Address.UnixPath: Equatable {
    public static func == (lhs: Self, rhs: Self) -> Bool {
        guard lhs.length == rhs.length else { return false }
        return withUnsafeBytes(of: lhs.bytes) { b1 in
            withUnsafeBytes(of: rhs.bytes) { b2 in
                for i in 0..<lhs.length {
                    if b1[i] != b2[i] { return false }
                }
                return true
            }
        }
    }
}

// MARK: - Factory Methods

extension IO.NonBlocking.Socket.Address {
    /// Creates an IPv4 socket address.
    ///
    /// - Parameters:
    ///   - address: The IPv4 address.
    ///   - port: Port number (host byte order).
    /// - Returns: An IPv4 socket address.
    public static func ipv4(_ address: IPv4.Address, port: UInt16) -> Self {
        Self(storage: .ipv4(address: address, port: port))
    }

    /// Creates an IPv4 address from octets.
    ///
    /// - Parameters:
    ///   - a: First octet.
    ///   - b: Second octet.
    ///   - c: Third octet.
    ///   - d: Fourth octet.
    ///   - port: Port number (host byte order).
    /// - Returns: An IPv4 socket address.
    public static func ipv4(
        _ a: UInt8, _ b: UInt8, _ c: UInt8, _ d: UInt8,
        port: UInt16
    ) -> Self {
        Self(storage: .ipv4(address: IPv4.Address(a, b, c, d), port: port))
    }

    /// Creates an IPv4 loopback address (127.0.0.1).
    ///
    /// - Parameter port: Port number (host byte order).
    /// - Returns: An IPv4 loopback address.
    public static func ipv4Loopback(port: UInt16) -> Self {
        ipv4(.loopback, port: port)
    }

    /// Creates an IPv4 any address (0.0.0.0).
    ///
    /// Used for binding to all interfaces.
    ///
    /// - Parameter port: Port number (host byte order).
    /// - Returns: An IPv4 any address.
    public static func ipv4Any(port: UInt16) -> Self {
        ipv4(.any, port: port)
    }

    /// Creates an IPv6 socket address.
    ///
    /// - Parameters:
    ///   - address: The IPv6 address.
    ///   - port: Port number (host byte order).
    ///   - flowInfo: IPv6 flow information (default 0).
    ///   - scopeId: IPv6 scope ID (default 0).
    /// - Returns: An IPv6 socket address.
    public static func ipv6(
        _ address: IPv6.Address,
        port: UInt16,
        flowInfo: UInt32 = 0,
        scopeId: UInt32 = 0
    ) -> Self {
        Self(storage: .ipv6(address: address, port: port, flowInfo: flowInfo, scopeId: scopeId))
    }

    /// Creates an IPv6 loopback address (::1).
    ///
    /// - Parameter port: Port number (host byte order).
    /// - Returns: An IPv6 loopback address.
    public static func ipv6Loopback(port: UInt16) -> Self {
        ipv6(.loopback, port: port)
    }

    /// Creates an IPv6 any address (::).
    ///
    /// Used for binding to all interfaces.
    ///
    /// - Parameter port: Port number (host byte order).
    /// - Returns: An IPv6 any address.
    public static func ipv6Any(port: UInt16) -> Self {
        ipv6(.unspecified, port: port)
    }

    /// Creates a Unix domain socket address.
    ///
    /// - Parameter path: The socket file path.
    /// - Returns: A Unix address, or `nil` if the path is too long.
    public static func unix(_ path: StaticString) -> Self? {
        guard let unixPath = UnixPath(path) else { return nil }
        return Self(storage: .unix(path: unixPath))
    }
}

// MARK: - Properties

extension IO.NonBlocking.Socket.Address {
    /// The port number (for IP addresses).
    ///
    /// Returns `nil` for Unix domain socket addresses.
    public var port: UInt16? {
        switch storage {
        case .ipv4(_, let port):
            return port
        case .ipv6(_, let port, _, _):
            return port
        case .unix:
            return nil
        }
    }

    /// The IPv4 address, if this is an IPv4 socket address.
    public var ipv4Address: IPv4.Address? {
        if case .ipv4(let address, _) = storage {
            return address
        }
        return nil
    }

    /// The IPv6 address, if this is an IPv6 socket address.
    public var ipv6Address: IPv6.Address? {
        if case .ipv6(let address, _, _, _) = storage {
            return address
        }
        return nil
    }

    /// Whether this is an IPv4 address.
    public var isIPv4: Bool {
        if case .ipv4 = storage { return true }
        return false
    }

    /// Whether this is an IPv6 address.
    public var isIPv6: Bool {
        if case .ipv6 = storage { return true }
        return false
    }

    /// Whether this is a Unix domain socket address.
    public var isUnix: Bool {
        if case .unix = storage { return true }
        return false
    }
}

// MARK: - sockaddr Conversion

extension IO.NonBlocking.Socket.Address {
    /// The socket address family.
    public var family: Int32 {
        switch storage {
        case .ipv4:
            return AF_INET
        case .ipv6:
            return AF_INET6
        case .unix:
            return AF_UNIX
        }
    }

    /// Calls a closure with a pointer to the sockaddr structure.
    ///
    /// This is the primary way to use the address with socket syscalls.
    ///
    /// - Parameter body: A closure that receives the sockaddr pointer and length.
    /// - Returns: The value returned by the closure.
    func withSockAddr<R>(
        _ body: (UnsafePointer<sockaddr>, socklen_t) throws -> R
    ) rethrows -> R {
        switch storage {
        case .ipv4(let address, let port):
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = port.bigEndian
            // IPv4.Address rawValue is in logical big-endian (127 in high byte)
            // Convert to network byte order for s_addr
            addr.sin_addr.s_addr = address.rawValue.bigEndian
            #if canImport(Darwin)
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            #endif

            return try withUnsafePointer(to: &addr) { ptr in
                try ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                    try body(sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }

        case .ipv6(let address, let port, let flowInfo, let scopeId):
            var addr = sockaddr_in6()
            addr.sin6_family = sa_family_t(AF_INET6)
            addr.sin6_port = port.bigEndian
            addr.sin6_flowinfo = flowInfo.bigEndian
            addr.sin6_scope_id = scopeId
            #if canImport(Darwin)
            addr.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            #endif

            // Serialize via Binary.Serializable
            let bytes: [UInt8] = [UInt8](address)
            withUnsafeMutableBytes(of: &addr.sin6_addr) { dest in
                for i in 0..<16 { dest[i] = bytes[i] }
            }

            return try withUnsafePointer(to: &addr) { ptr in
                try ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                    try body(sockPtr, socklen_t(MemoryLayout<sockaddr_in6>.size))
                }
            }

        case .unix(let path):
            var addr = sockaddr_un()
            addr.sun_family = sa_family_t(AF_UNIX)
            #if canImport(Darwin)
            addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
            #endif

            withUnsafeMutableBytes(of: &addr.sun_path) { dest in
                withUnsafeBytes(of: path.bytes) { src in
                    let copyLen = min(dest.count, src.count)
                    dest.copyMemory(from: UnsafeRawBufferPointer(rebasing: src.prefix(copyLen)))
                }
            }

            return try withUnsafePointer(to: &addr) { ptr in
                try ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                    try body(sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
        }
    }

    /// Creates an address from a sockaddr structure.
    ///
    /// - Parameters:
    ///   - addr: Pointer to the sockaddr structure.
    ///   - length: The length of the structure.
    /// - Returns: An address, or `nil` if the family is unsupported.
    static func from(
        sockaddr addr: UnsafePointer<sockaddr>,
        length: socklen_t
    ) -> Self? {
        let family = Int32(addr.pointee.sa_family)

        switch family {
        case AF_INET:
            guard length >= socklen_t(MemoryLayout<sockaddr_in>.size) else { return nil }
            return addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { ptr in
                let sin = ptr.pointee
                // s_addr is in network byte order, convert to logical big-endian for rawValue
                let ipv4 = IPv4.Address(rawValue: UInt32(bigEndian: sin.sin_addr.s_addr))
                return .ipv4(ipv4, port: UInt16(bigEndian: sin.sin_port))
            }

        case AF_INET6:
            guard length >= socklen_t(MemoryLayout<sockaddr_in6>.size) else { return nil }
            return addr.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { ptr in
                let sin6 = ptr.pointee

                // Copy bytes via Array initializer for Binary.Serializable
                let bytes: [UInt8] = withUnsafeBytes(of: sin6.sin6_addr) { src in
                    [UInt8](src)
                }
                guard let ipv6 = try? IPv6.Address(binary: bytes) else {
                    return nil
                }

                return .ipv6(
                    ipv6,
                    port: UInt16(bigEndian: sin6.sin6_port),
                    flowInfo: UInt32(bigEndian: sin6.sin6_flowinfo),
                    scopeId: sin6.sin6_scope_id
                )
            }

        case AF_UNIX:
            guard length >= socklen_t(MemoryLayout<sockaddr_un>.size) else { return nil }
            return addr.withMemoryRebound(to: sockaddr_un.self, capacity: 1) { ptr in
                let sun = ptr.pointee
                return withUnsafeBytes(of: sun.sun_path) { pathBytes in
                    let buffer = pathBytes.bindMemory(to: UInt8.self)
                    guard let unixPath = UnixPath(bytes: buffer) else { return nil }
                    return Self(storage: .unix(path: unixPath))
                }
            }

        default:
            return nil
        }
    }
}
