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

extension IO.NonBlocking.Socket {
    /// A network socket address.
    ///
    /// Supports IPv4, IPv6, and Unix domain socket addresses.
    /// No Foundation types are used - addresses are stored as raw values.
    ///
    /// ## Creation
    /// ```swift
    /// let ipv4 = Address.ipv4(127, 0, 0, 1, port: 8080)
    /// let ipv6 = Address.ipv6Loopback(port: 8080)
    /// let unix = Address.unix("/tmp/my.sock")
    /// ```
    ///
    /// ## Network Byte Order
    /// Addresses are stored in host byte order internally.
    /// Conversion to network byte order happens when creating sockaddr structures.
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
    enum Storage: Sendable {
        /// IPv4 address (4 bytes) + port.
        case ipv4(a: UInt8, b: UInt8, c: UInt8, d: UInt8, port: UInt16)

        /// IPv6 address (16 bytes) + port + flow info + scope ID.
        case ipv6(
            bytes: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8),
            port: UInt16,
            flowInfo: UInt32,
            scopeId: UInt32
        )

        /// Unix domain socket path.
        ///
        /// Stored as a fixed-size buffer (max 104 bytes on Darwin, 108 on Linux).
        /// The path must be null-terminated.
        case unix(path: UnixPath)
    }
}

// MARK: - Storage Equatable

extension IO.NonBlocking.Socket.Address.Storage: Equatable {
    @usableFromInline
    static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case (.ipv4(let a1, let b1, let c1, let d1, let p1),
              .ipv4(let a2, let b2, let c2, let d2, let p2)):
            return a1 == a2 && b1 == b2 && c1 == c2 && d1 == d2 && p1 == p2

        case (.ipv6(let bytes1, let port1, let flow1, let scope1),
              .ipv6(let bytes2, let port2, let flow2, let scope2)):
            guard port1 == port2 && flow1 == flow2 && scope1 == scope2 else { return false }
            return withUnsafeBytes(of: bytes1) { b1 in
                withUnsafeBytes(of: bytes2) { b2 in
                    b1.elementsEqual(b2)
                }
            }

        case (.unix(let path1), .unix(let path2)):
            return path1 == path2

        default:
            return false
        }
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
                // Compare only up to the length (not the full buffer)
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
    /// Creates an IPv4 address.
    ///
    /// - Parameters:
    ///   - a: First octet.
    ///   - b: Second octet.
    ///   - c: Third octet.
    ///   - d: Fourth octet.
    ///   - port: Port number (host byte order).
    /// - Returns: An IPv4 address.
    
    public static func ipv4(
        _ a: UInt8, _ b: UInt8, _ c: UInt8, _ d: UInt8,
        port: UInt16
    ) -> Self {
        Self(storage: .ipv4(a: a, b: b, c: c, d: d, port: port))
    }

    /// Creates an IPv4 loopback address (127.0.0.1).
    ///
    /// - Parameter port: Port number (host byte order).
    /// - Returns: An IPv4 loopback address.
    
    public static func ipv4Loopback(port: UInt16) -> Self {
        ipv4(127, 0, 0, 1, port: port)
    }

    /// Creates an IPv4 any address (0.0.0.0).
    ///
    /// Used for binding to all interfaces.
    ///
    /// - Parameter port: Port number (host byte order).
    /// - Returns: An IPv4 any address.
    
    public static func ipv4Any(port: UInt16) -> Self {
        ipv4(0, 0, 0, 0, port: port)
    }

    /// Creates an IPv6 address.
    ///
    /// - Parameters:
    ///   - bytes: 16 bytes of the IPv6 address.
    ///   - port: Port number (host byte order).
    ///   - flowInfo: IPv6 flow information (default 0).
    ///   - scopeId: IPv6 scope ID (default 0).
    /// - Returns: An IPv6 address.
    
    public static func ipv6(
        _ bytes: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                  UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8),
        port: UInt16,
        flowInfo: UInt32 = 0,
        scopeId: UInt32 = 0
    ) -> Self {
        Self(storage: .ipv6(bytes: bytes, port: port, flowInfo: flowInfo, scopeId: scopeId))
    }

    /// Creates an IPv6 loopback address (::1).
    ///
    /// - Parameter port: Port number (host byte order).
    /// - Returns: An IPv6 loopback address.
    
    public static func ipv6Loopback(port: UInt16) -> Self {
        ipv6((0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1), port: port)
    }

    /// Creates an IPv6 any address (::).
    ///
    /// Used for binding to all interfaces.
    ///
    /// - Parameter port: Port number (host byte order).
    /// - Returns: An IPv6 any address.
    
    public static func ipv6Any(port: UInt16) -> Self {
        ipv6((0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0), port: port)
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
        case .ipv4(_, _, _, _, let port):
            return port
        case .ipv6(_, let port, _, _):
            return port
        case .unix:
            return nil
        }
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
        case .ipv4(let a, let b, let c, let d, let port):
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = port.bigEndian
            addr.sin_addr.s_addr = UInt32(a) | (UInt32(b) << 8) | (UInt32(c) << 16) | (UInt32(d) << 24)
            #if canImport(Darwin)
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            #endif

            return try withUnsafePointer(to: &addr) { ptr in
                try ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                    try body(sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }

        case .ipv6(let bytes, let port, let flowInfo, let scopeId):
            var addr = sockaddr_in6()
            addr.sin6_family = sa_family_t(AF_INET6)
            addr.sin6_port = port.bigEndian
            addr.sin6_flowinfo = flowInfo.bigEndian
            addr.sin6_scope_id = scopeId
            #if canImport(Darwin)
            addr.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            #endif

            withUnsafeMutableBytes(of: &addr.sin6_addr) { dest in
                withUnsafeBytes(of: bytes) { src in
                    dest.copyMemory(from: src)
                }
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
                let ip = sin.sin_addr.s_addr
                return .ipv4(
                    UInt8(ip & 0xFF),
                    UInt8((ip >> 8) & 0xFF),
                    UInt8((ip >> 16) & 0xFF),
                    UInt8((ip >> 24) & 0xFF),
                    port: UInt16(bigEndian: sin.sin_port)
                )
            }

        case AF_INET6:
            guard length >= socklen_t(MemoryLayout<sockaddr_in6>.size) else { return nil }
            return addr.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { ptr in
                let sin6 = ptr.pointee
                var bytes: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                            UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) =
                    (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)

                withUnsafeBytes(of: sin6.sin6_addr) { src in
                    withUnsafeMutableBytes(of: &bytes) { dest in
                        dest.copyMemory(from: src)
                    }
                }

                return .ipv6(
                    bytes,
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
