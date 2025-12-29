//
//  IO.NonBlocking.Socket.Address.Tests.swift
//  swift-io
//

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

import StandardsTestSupport
import Testing
import IPv4_Standard
import IPv6_Standard

@testable import IO_NonBlocking_Socket

extension IO.NonBlocking.Socket.Address {
    #TestSuites
}

// MARK: - IPv4 Tests

extension IO.NonBlocking.Socket.Address.Test {
    @Suite struct IPv4 {}
}

extension IO.NonBlocking.Socket.Address.Test.IPv4 {
    @Test("ipv4 factory creates correct address")
    func ipv4Factory() {
        let addr = IO.NonBlocking.Socket.Address.ipv4(192, 168, 1, 100, port: 8080)

        #expect(addr.isIPv4)
        #expect(!addr.isIPv6)
        #expect(!addr.isUnix)
        #expect(addr.port == 8080)
        #expect(addr.ipv4Address == IPv4.Address(192, 168, 1, 100))
        #expect(addr.ipv6Address == nil)
    }

    @Test("ipv4 loopback creates 127.0.0.1")
    func ipv4Loopback() {
        let addr = IO.NonBlocking.Socket.Address.ipv4Loopback(port: 3000)

        #expect(addr.isIPv4)
        #expect(addr.port == 3000)
        #expect(addr.ipv4Address == .loopback)
    }

    @Test("ipv4 any creates 0.0.0.0")
    func ipv4Any() {
        let addr = IO.NonBlocking.Socket.Address.ipv4Any(port: 0)

        #expect(addr.isIPv4)
        #expect(addr.port == 0)
        #expect(addr.ipv4Address == .any)
    }

    @Test("ipv4 equality")
    func ipv4Equality() {
        let a = IO.NonBlocking.Socket.Address.ipv4(10, 0, 0, 1, port: 443)
        let b = IO.NonBlocking.Socket.Address.ipv4(10, 0, 0, 1, port: 443)
        let c = IO.NonBlocking.Socket.Address.ipv4(10, 0, 0, 1, port: 80)
        let d = IO.NonBlocking.Socket.Address.ipv4(10, 0, 0, 2, port: 443)

        #expect(a == b)
        #expect(a != c)  // Different port
        #expect(a != d)  // Different address
    }

    @Test("ipv4 sockaddr roundtrip")
    func ipv4SockaddrRoundtrip() {
        let original = IO.NonBlocking.Socket.Address.ipv4(172, 16, 0, 1, port: 9999)

        // Convert to sockaddr and back
        let roundtripped = original.withSockAddr { addr, len in
            IO.NonBlocking.Socket.Address.from(sockaddr: addr, length: len)
        }

        #expect(roundtripped == original)
    }

    @Test("ipv4 family is AF_INET")
    func ipv4Family() {
        let addr = IO.NonBlocking.Socket.Address.ipv4Loopback(port: 80)
        #expect(addr.family == AF_INET)
    }
}

// MARK: - IPv6 Tests

extension IO.NonBlocking.Socket.Address.Test {
    @Suite struct IPv6 {}
}

extension IO.NonBlocking.Socket.Address.Test.IPv6 {
    @Test("ipv6 factory creates correct address")
    func ipv6Factory() throws {
        let ipv6Addr = try RFC_4291.IPv6.Address("2001:db8::1")
        let addr = IO.NonBlocking.Socket.Address.ipv6(ipv6Addr, port: 8080)

        #expect(!addr.isIPv4)
        #expect(addr.isIPv6)
        #expect(!addr.isUnix)
        #expect(addr.port == 8080)
        #expect(addr.ipv6Address == ipv6Addr)
        #expect(addr.ipv4Address == nil)
    }

    @Test("ipv6 loopback creates ::1")
    func ipv6Loopback() {
        let addr = IO.NonBlocking.Socket.Address.ipv6Loopback(port: 3000)

        #expect(addr.isIPv6)
        #expect(addr.port == 3000)
        #expect(addr.ipv6Address == .loopback)
    }

    @Test("ipv6 any creates ::")
    func ipv6Any() {
        let addr = IO.NonBlocking.Socket.Address.ipv6Any(port: 0)

        #expect(addr.isIPv6)
        #expect(addr.port == 0)
        #expect(addr.ipv6Address == .unspecified)
    }

    @Test("ipv6 equality")
    func ipv6Equality() throws {
        let ipv6A = try RFC_4291.IPv6.Address("fe80::1")
        let ipv6B = try RFC_4291.IPv6.Address("fe80::2")

        let a = IO.NonBlocking.Socket.Address.ipv6(ipv6A, port: 443)
        let b = IO.NonBlocking.Socket.Address.ipv6(ipv6A, port: 443)
        let c = IO.NonBlocking.Socket.Address.ipv6(ipv6A, port: 80)
        let d = IO.NonBlocking.Socket.Address.ipv6(ipv6B, port: 443)

        #expect(a == b)
        #expect(a != c)  // Different port
        #expect(a != d)  // Different address
    }

    @Test("ipv6 sockaddr roundtrip")
    func ipv6SockaddrRoundtrip() throws {
        let ipv6Addr = try RFC_4291.IPv6.Address("2001:db8:85a3::8a2e:370:7334")
        let original = IO.NonBlocking.Socket.Address.ipv6(ipv6Addr, port: 9999)

        // Convert to sockaddr and back
        let roundtripped = original.withSockAddr { addr, len in
            IO.NonBlocking.Socket.Address.from(sockaddr: addr, length: len)
        }

        #expect(roundtripped == original)
    }

    @Test("ipv6 loopback sockaddr roundtrip")
    func ipv6LoopbackRoundtrip() {
        let original = IO.NonBlocking.Socket.Address.ipv6Loopback(port: 8443)

        let roundtripped = original.withSockAddr { addr, len in
            IO.NonBlocking.Socket.Address.from(sockaddr: addr, length: len)
        }

        #expect(roundtripped == original)
    }

    @Test("ipv6 family is AF_INET6")
    func ipv6Family() {
        let addr = IO.NonBlocking.Socket.Address.ipv6Loopback(port: 80)
        #expect(addr.family == AF_INET6)
    }

    @Test("ipv6 with flow info and scope id")
    func ipv6FlowInfoScopeId() {
        let addr = IO.NonBlocking.Socket.Address.ipv6(
            .loopback,
            port: 8080,
            flowInfo: 12345,
            scopeId: 1
        )

        #expect(addr.port == 8080)
        #expect(addr.ipv6Address == .loopback)

        // Roundtrip should preserve all fields
        let roundtripped = addr.withSockAddr { sockaddr, len in
            IO.NonBlocking.Socket.Address.from(sockaddr: sockaddr, length: len)
        }

        #expect(roundtripped == addr)
    }
}

// MARK: - Unix Socket Tests

extension IO.NonBlocking.Socket.Address.Test {
    @Suite struct Unix {}
}

extension IO.NonBlocking.Socket.Address.Test.Unix {
    @Test("unix factory creates correct address")
    func unixFactory() {
        let addr = IO.NonBlocking.Socket.Address.unix("/tmp/test.sock")

        #expect(addr != nil)
        #expect(addr?.isUnix == true)
        #expect(addr?.isIPv4 == false)
        #expect(addr?.isIPv6 == false)
        #expect(addr?.port == nil)
    }

    @Test("unix family is AF_UNIX")
    func unixFamily() {
        let addr = IO.NonBlocking.Socket.Address.unix("/tmp/test.sock")
        #expect(addr?.family == AF_UNIX)
    }

    @Test("unix equality")
    func unixEquality() {
        let a = IO.NonBlocking.Socket.Address.unix("/tmp/a.sock")
        let b = IO.NonBlocking.Socket.Address.unix("/tmp/a.sock")
        let c = IO.NonBlocking.Socket.Address.unix("/tmp/b.sock")

        #expect(a == b)
        #expect(a != c)
    }

    @Test("unix sockaddr roundtrip")
    func unixSockaddrRoundtrip() {
        guard let original = IO.NonBlocking.Socket.Address.unix("/tmp/roundtrip.sock") else {
            Issue.record("Failed to create unix address")
            return
        }

        let roundtripped = original.withSockAddr { addr, len in
            IO.NonBlocking.Socket.Address.from(sockaddr: addr, length: len)
        }

        #expect(roundtripped == original)
    }
}

// MARK: - Cross-Type Tests

extension IO.NonBlocking.Socket.Address.Test {
    @Suite struct CrossType {}
}

extension IO.NonBlocking.Socket.Address.Test.CrossType {
    @Test("ipv4 and ipv6 are not equal")
    func ipv4NotEqualIPv6() {
        let ipv4 = IO.NonBlocking.Socket.Address.ipv4Loopback(port: 8080)
        let ipv6 = IO.NonBlocking.Socket.Address.ipv6Loopback(port: 8080)

        #expect(ipv4 != ipv6)
    }

    @Test("ip and unix are not equal")
    func ipNotEqualUnix() {
        let ipv4 = IO.NonBlocking.Socket.Address.ipv4Loopback(port: 80)
        let unix = IO.NonBlocking.Socket.Address.unix("/tmp/test.sock")

        #expect(ipv4 != unix)
    }
}
