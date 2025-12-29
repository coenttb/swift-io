//
//  IO.NonBlocking.Socket.TCP.Tests.swift
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

@testable import IO_NonBlocking
import IO_NonBlocking_Kqueue

extension IO.NonBlocking.Socket.TCP {
    #TestSuites
}

// MARK: - Connect/Accept Tests

extension IO.NonBlocking.Socket.TCP.Test {
    @Suite struct ConnectAccept {}
}

extension IO.NonBlocking.Socket.TCP.Test.ConnectAccept {
    @Test("connect to listening server succeeds")
    func connectToServer() async throws {
        let executor = IO.Executor.Thread()
        let selector = try await IO.NonBlocking.Selector.make(
            driver: IO.NonBlocking.Kqueue.driver(),
            executor: executor
        )
        defer { Task { await selector.shutdown() } }

        var listener = try await IO.NonBlocking.Socket.Listener.bind(
            to: .ipv4Loopback(port: 0),
            on: selector
        )
        let port = listener.localAddress.port!

        // Sequential: connect completes via kernel backlog, then accept
        var client = try await IO.NonBlocking.Socket.TCP.connect(
            to: .ipv4Loopback(port: port),
            on: selector
        )
        var server = try await listener.accept()

        #expect(client.remoteAddress.port == port)
        #expect(server.remoteAddress.isIPv4)

        try await client.close()
        try await server.close()
        try await listener.close()
    }

    @Test("accept returns correct remote address")
    func acceptRemoteAddress() async throws {
        let executor = IO.Executor.Thread()
        let selector = try await IO.NonBlocking.Selector.make(
            driver: IO.NonBlocking.Kqueue.driver(),
            executor: executor
        )
        defer { Task { await selector.shutdown() } }

        var listener = try await IO.NonBlocking.Socket.Listener.bind(
            to: .ipv4Loopback(port: 0),
            on: selector
        )
        let port = listener.localAddress.port!

        var client = try await IO.NonBlocking.Socket.TCP.connect(
            to: .ipv4Loopback(port: port),
            on: selector
        )
        var server = try await listener.accept()

        #expect(server.remoteAddress.ipv4Address == .loopback)

        try await client.close()
        try await server.close()
        try await listener.close()
    }

    @Test("IPv6 connect and accept")
    func ipv6ConnectAccept() async throws {
        let executor = IO.Executor.Thread()
        let selector = try await IO.NonBlocking.Selector.make(
            driver: IO.NonBlocking.Kqueue.driver(),
            executor: executor
        )
        defer { Task { await selector.shutdown() } }

        var listener = try await IO.NonBlocking.Socket.Listener.bind(
            to: .ipv6Loopback(port: 0),
            on: selector
        )
        let port = listener.localAddress.port!

        var client = try await IO.NonBlocking.Socket.TCP.connect(
            to: .ipv6Loopback(port: port),
            on: selector
        )
        var server = try await listener.accept()

        #expect(client.remoteAddress.isIPv6)
        #expect(server.remoteAddress.isIPv6)

        try await client.close()
        try await server.close()
        try await listener.close()
    }
}

// MARK: - Read/Write Tests

extension IO.NonBlocking.Socket.TCP.Test {
    @Suite struct ReadWrite {}
}

extension IO.NonBlocking.Socket.TCP.Test.ReadWrite {
    @Test("write and read data")
    func writeAndRead() async throws {
        let executor = IO.Executor.Thread()
        let selector = try await IO.NonBlocking.Selector.make(
            driver: IO.NonBlocking.Kqueue.driver(),
            executor: executor
        )
        defer { Task { await selector.shutdown() } }

        var listener = try await IO.NonBlocking.Socket.Listener.bind(
            to: .ipv4Loopback(port: 0),
            on: selector
        )
        let port = listener.localAddress.port!

        var client = try await IO.NonBlocking.Socket.TCP.connect(
            to: .ipv4Loopback(port: port),
            on: selector
        )
        var server = try await listener.accept()

        let testData: [UInt8] = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]
        let bytesWritten = try await client.write(testData)
        #expect(bytesWritten == testData.count)

        var buffer = [UInt8](repeating: 0, count: 32)
        let bytesRead = try await server.read(into: &buffer)
        #expect(bytesRead == testData.count)
        #expect(Array(buffer[..<bytesRead]) == testData)

        try await client.close()
        try await server.close()
        try await listener.close()
    }

    @Test("bidirectional communication")
    func bidirectional() async throws {
        let executor = IO.Executor.Thread()
        let selector = try await IO.NonBlocking.Selector.make(
            driver: IO.NonBlocking.Kqueue.driver(),
            executor: executor
        )
        defer { Task { await selector.shutdown() } }

        var listener = try await IO.NonBlocking.Socket.Listener.bind(
            to: .ipv4Loopback(port: 0),
            on: selector
        )
        let port = listener.localAddress.port!

        var client = try await IO.NonBlocking.Socket.TCP.connect(
            to: .ipv4Loopback(port: port),
            on: selector
        )
        var server = try await listener.accept()

        // Client -> Server
        let clientMsg: [UInt8] = Array("hello server".utf8)
        _ = try await client.write(clientMsg)

        var serverBuffer = [UInt8](repeating: 0, count: 64)
        let serverRead = try await server.read(into: &serverBuffer)
        #expect(Array(serverBuffer[..<serverRead]) == clientMsg)

        // Server -> Client
        let serverMsg: [UInt8] = Array("hello client".utf8)
        _ = try await server.write(serverMsg)

        var clientBuffer = [UInt8](repeating: 0, count: 64)
        let clientRead = try await client.read(into: &clientBuffer)
        #expect(Array(clientBuffer[..<clientRead]) == serverMsg)

        try await client.close()
        try await server.close()
        try await listener.close()
    }

    @Test("read returns 0 on peer close")
    func readReturnsZeroOnPeerClose() async throws {
        let executor = IO.Executor.Thread()
        let selector = try await IO.NonBlocking.Selector.make(
            driver: IO.NonBlocking.Kqueue.driver(),
            executor: executor
        )
        defer { Task { await selector.shutdown() } }

        var listener = try await IO.NonBlocking.Socket.Listener.bind(
            to: .ipv4Loopback(port: 0),
            on: selector
        )
        let port = listener.localAddress.port!

        var client = try await IO.NonBlocking.Socket.TCP.connect(
            to: .ipv4Loopback(port: port),
            on: selector
        )
        var server = try await listener.accept()

        try await client.close()

        var buffer = [UInt8](repeating: 0, count: 32)
        let bytesRead = try await server.read(into: &buffer)
        #expect(bytesRead == 0)

        try await server.close()
        try await listener.close()
    }
}

// MARK: - Half-Close Tests

extension IO.NonBlocking.Socket.TCP.Test {
    @Suite struct HalfClose {}
}

extension IO.NonBlocking.Socket.TCP.Test.HalfClose {
    // Test EOF detection after peer shutdownWrite
    // The kqueue driver should detect FIN and return read-ready with EOF
    @Test("shutdown write causes peer EOF")
    func shutdownWriteCausesPeerEOF() async throws {
        let executor = IO.Executor.Thread()
        let selector = try await IO.NonBlocking.Selector.make(
            driver: IO.NonBlocking.Kqueue.driver(),
            executor: executor
        )
        defer { Task { await selector.shutdown() } }

        var listener = try await IO.NonBlocking.Socket.Listener.bind(
            to: .ipv4Loopback(port: 0),
            on: selector
        )
        let port = listener.localAddress.port!

        var client = try await IO.NonBlocking.Socket.TCP.connect(
            to: .ipv4Loopback(port: port),
            on: selector
        )
        var server = try await listener.accept()

        try await client.shutdownWrite()

        var buffer = [UInt8](repeating: 0, count: 32)
        let bytesRead = try await server.read(into: &buffer)
        #expect(bytesRead == 0)

        let serverMsg: [UInt8] = Array("response".utf8)
        let bytesWritten = try await server.write(serverMsg)
        #expect(bytesWritten == serverMsg.count)

        var clientBuffer = [UInt8](repeating: 0, count: 32)
        let clientRead = try await client.read(into: &clientBuffer)
        #expect(Array(clientBuffer[..<clientRead]) == serverMsg)

        try await client.close()
        try await server.close()
        try await listener.close()
    }

    @Test("shutdown read returns 0 on subsequent reads")
    func shutdownReadReturnsZero() async throws {
        let executor = IO.Executor.Thread()
        let selector = try await IO.NonBlocking.Selector.make(
            driver: IO.NonBlocking.Kqueue.driver(),
            executor: executor
        )
        defer { Task { await selector.shutdown() } }

        var listener = try await IO.NonBlocking.Socket.Listener.bind(
            to: .ipv4Loopback(port: 0),
            on: selector
        )
        let port = listener.localAddress.port!

        var client = try await IO.NonBlocking.Socket.TCP.connect(
            to: .ipv4Loopback(port: port),
            on: selector
        )
        var server = try await listener.accept()

        try await client.shutdownRead()

        var buffer = [UInt8](repeating: 0, count: 32)
        let bytesRead = try await client.read(into: &buffer)
        #expect(bytesRead == 0)

        try await client.close()
        try await server.close()
        try await listener.close()
    }
}

// MARK: - Listener Tests

extension IO.NonBlocking.Socket.Listener {
    #TestSuites
}

extension IO.NonBlocking.Socket.Listener.Test {
    @Suite struct Bind {}
}

extension IO.NonBlocking.Socket.Listener.Test.Bind {
    @Test("bind to ephemeral port assigns port")
    func bindEphemeralPort() async throws {
        let executor = IO.Executor.Thread()
        let selector = try await IO.NonBlocking.Selector.make(
            driver: IO.NonBlocking.Kqueue.driver(),
            executor: executor
        )
        defer { Task { await selector.shutdown() } }

        let listener = try await IO.NonBlocking.Socket.Listener.bind(
            to: .ipv4Loopback(port: 0),
            on: selector
        )

        #expect(listener.localAddress.port != nil)
        #expect(listener.localAddress.port! > 0)

        try await listener.close()
    }

    @Test("bind to IPv6 succeeds")
    func bindIPv6() async throws {
        let executor = IO.Executor.Thread()
        let selector = try await IO.NonBlocking.Selector.make(
            driver: IO.NonBlocking.Kqueue.driver(),
            executor: executor
        )
        defer { Task { await selector.shutdown() } }

        let listener = try await IO.NonBlocking.Socket.Listener.bind(
            to: .ipv6Loopback(port: 0),
            on: selector
        )

        #expect(listener.localAddress.isIPv6)
        #expect(listener.localAddress.port != nil)

        try await listener.close()
    }
}
