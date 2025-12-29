//
//  IO.NonBlocking.Socket.UDP.Tests.swift
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

extension IO.NonBlocking.Socket.UDP {
    #TestSuites
}

// MARK: - Bind Tests

extension IO.NonBlocking.Socket.UDP.Test {
    @Suite struct Bind {}
}

extension IO.NonBlocking.Socket.UDP.Test.Bind {
    @Test("bind to ephemeral port assigns port")
    func bindEphemeralPort() async throws {
        let executor = IO.Executor.Thread()
        let selector = try await IO.NonBlocking.Selector.make(
            driver: IO.NonBlocking.Kqueue.driver(),
            executor: executor
        )
        defer { Task { await selector.shutdown() } }

        let udp = try await IO.NonBlocking.Socket.UDP.bind(
            to: .ipv4Loopback(port: 0),
            on: selector
        )

        #expect(udp.localAddress?.port != nil)
        #expect(udp.localAddress!.port! > 0)

        try await udp.close()
    }

    @Test("bind to IPv6 succeeds")
    func bindIPv6() async throws {
        let executor = IO.Executor.Thread()
        let selector = try await IO.NonBlocking.Selector.make(
            driver: IO.NonBlocking.Kqueue.driver(),
            executor: executor
        )
        defer { Task { await selector.shutdown() } }

        let udp = try await IO.NonBlocking.Socket.UDP.bind(
            to: .ipv6Loopback(port: 0),
            on: selector
        )

        #expect(udp.localAddress?.isIPv6 == true)

        try await udp.close()
    }

    @Test("unbound IPv4 has no local address")
    func unboundIPv4NoLocalAddress() async throws {
        let executor = IO.Executor.Thread()
        let selector = try await IO.NonBlocking.Selector.make(
            driver: IO.NonBlocking.Kqueue.driver(),
            executor: executor
        )
        defer { Task { await selector.shutdown() } }

        let udp = try await IO.NonBlocking.Socket.UDP.unboundIPv4(on: selector)

        #expect(udp.localAddress == nil)

        try await udp.close()
    }

    @Test("unbound IPv6 has no local address")
    func unboundIPv6NoLocalAddress() async throws {
        let executor = IO.Executor.Thread()
        let selector = try await IO.NonBlocking.Selector.make(
            driver: IO.NonBlocking.Kqueue.driver(),
            executor: executor
        )
        defer { Task { await selector.shutdown() } }

        let udp = try await IO.NonBlocking.Socket.UDP.unboundIPv6(on: selector)

        #expect(udp.localAddress == nil)

        try await udp.close()
    }
}

// MARK: - Sendto/Recvfrom Tests

extension IO.NonBlocking.Socket.UDP.Test {
    @Suite struct SendtoRecvfrom {}
}

extension IO.NonBlocking.Socket.UDP.Test.SendtoRecvfrom {
    @Test("sendto and recvfrom datagram")
    func sendtoRecvfrom() async throws {
        let executor = IO.Executor.Thread()
        let selector = try await IO.NonBlocking.Selector.make(
            driver: IO.NonBlocking.Kqueue.driver(),
            executor: executor
        )
        defer { Task { await selector.shutdown() } }

        // Create receiver
        var receiver = try await IO.NonBlocking.Socket.UDP.bind(
            to: .ipv4Loopback(port: 0),
            on: selector
        )
        let receiverPort = receiver.localAddress!.port!

        // Create sender
        var sender = try await IO.NonBlocking.Socket.UDP.unboundIPv4(on: selector)

        // Send datagram
        let testData: [UInt8] = Array("hello udp".utf8)
        let bytesSent = try await sender.sendto(
            testData,
            to: .ipv4Loopback(port: receiverPort)
        )
        #expect(bytesSent == testData.count)

        // Receive datagram
        var buffer = [UInt8](repeating: 0, count: 64)
        let (bytesReceived, senderAddr) = try await receiver.recvfrom(into: &buffer)

        #expect(bytesReceived == testData.count)
        #expect(Array(buffer[..<bytesReceived]) == testData)
        #expect(senderAddr.ipv4Address == .loopback)

        try await sender.close()
        try await receiver.close()
    }

    @Test("sendto IPv6 datagram")
    func sendtoIPv6() async throws {
        let executor = IO.Executor.Thread()
        let selector = try await IO.NonBlocking.Selector.make(
            driver: IO.NonBlocking.Kqueue.driver(),
            executor: executor
        )
        defer { Task { await selector.shutdown() } }

        var receiver = try await IO.NonBlocking.Socket.UDP.bind(
            to: .ipv6Loopback(port: 0),
            on: selector
        )
        let receiverPort = receiver.localAddress!.port!

        var sender = try await IO.NonBlocking.Socket.UDP.unboundIPv6(on: selector)

        let testData: [UInt8] = [0xDE, 0xAD, 0xBE, 0xEF]
        let bytesSent = try await sender.sendto(
            testData,
            to: .ipv6Loopback(port: receiverPort)
        )
        #expect(bytesSent == testData.count)

        var buffer = [UInt8](repeating: 0, count: 64)
        let (bytesReceived, senderAddr) = try await receiver.recvfrom(into: &buffer)

        #expect(bytesReceived == testData.count)
        #expect(Array(buffer[..<bytesReceived]) == testData)
        #expect(senderAddr.isIPv6)

        try await sender.close()
        try await receiver.close()
    }

    @Test("bidirectional UDP communication")
    func bidirectional() async throws {
        let executor = IO.Executor.Thread()
        let selector = try await IO.NonBlocking.Selector.make(
            driver: IO.NonBlocking.Kqueue.driver(),
            executor: executor
        )
        defer { Task { await selector.shutdown() } }

        // Create two bound sockets
        var alice = try await IO.NonBlocking.Socket.UDP.bind(
            to: .ipv4Loopback(port: 0),
            on: selector
        )
        let alicePort = alice.localAddress!.port!

        var bob = try await IO.NonBlocking.Socket.UDP.bind(
            to: .ipv4Loopback(port: 0),
            on: selector
        )
        let bobPort = bob.localAddress!.port!

        // Alice -> Bob
        let aliceMsg: [UInt8] = Array("hi bob".utf8)
        _ = try await alice.sendto(aliceMsg, to: .ipv4Loopback(port: bobPort))

        var bobBuffer = [UInt8](repeating: 0, count: 64)
        let (bobRead, fromAlice) = try await bob.recvfrom(into: &bobBuffer)
        #expect(Array(bobBuffer[..<bobRead]) == aliceMsg)
        #expect(fromAlice.port == alicePort)

        // Bob -> Alice
        let bobMsg: [UInt8] = Array("hi alice".utf8)
        _ = try await bob.sendto(bobMsg, to: fromAlice)

        var aliceBuffer = [UInt8](repeating: 0, count: 64)
        let (aliceRead, fromBob) = try await alice.recvfrom(into: &aliceBuffer)
        #expect(Array(aliceBuffer[..<aliceRead]) == bobMsg)
        #expect(fromBob.port == bobPort)

        try await alice.close()
        try await bob.close()
    }
}

// MARK: - Connected Mode Tests

extension IO.NonBlocking.Socket.UDP.Test {
    @Suite struct ConnectedMode {}
}

extension IO.NonBlocking.Socket.UDP.Test.ConnectedMode {
    @Test("connect sets default destination")
    func connectSetsDestination() async throws {
        let executor = IO.Executor.Thread()
        let selector = try await IO.NonBlocking.Selector.make(
            driver: IO.NonBlocking.Kqueue.driver(),
            executor: executor
        )
        defer { Task { await selector.shutdown() } }

        var udp = try await IO.NonBlocking.Socket.UDP.unboundIPv4(on: selector)

        #expect(udp.connectedAddress == nil)

        let dest = IO.NonBlocking.Socket.Address.ipv4Loopback(port: 9999)
        try udp.connect(to: dest)

        #expect(udp.connectedAddress == dest)

        try await udp.close()
    }

    @Test("send and recv in connected mode")
    func sendRecvConnected() async throws {
        let executor = IO.Executor.Thread()
        let selector = try await IO.NonBlocking.Selector.make(
            driver: IO.NonBlocking.Kqueue.driver(),
            executor: executor
        )
        defer { Task { await selector.shutdown() } }

        // Create receiver
        var receiver = try await IO.NonBlocking.Socket.UDP.bind(
            to: .ipv4Loopback(port: 0),
            on: selector
        )
        let receiverPort = receiver.localAddress!.port!

        // Create sender and connect
        var sender = try await IO.NonBlocking.Socket.UDP.unboundIPv4(on: selector)
        try sender.connect(to: .ipv4Loopback(port: receiverPort))

        // Send using connected mode
        let testData: [UInt8] = Array("connected send".utf8)
        let bytesSent = try await sender.send(testData)
        #expect(bytesSent == testData.count)

        // Receive
        var buffer = [UInt8](repeating: 0, count: 64)
        let (bytesReceived, _) = try await receiver.recvfrom(into: &buffer)
        #expect(bytesReceived == testData.count)
        #expect(Array(buffer[..<bytesReceived]) == testData)

        try await sender.close()
        try await receiver.close()
    }

    @Test("send without connect throws notConnected")
    func sendWithoutConnectThrows() async throws {
        let executor = IO.Executor.Thread()
        let selector = try await IO.NonBlocking.Selector.make(
            driver: IO.NonBlocking.Kqueue.driver(),
            executor: executor
        )
        defer { Task { await selector.shutdown() } }

        var udp = try await IO.NonBlocking.Socket.UDP.unboundIPv4(on: selector)

        let testData: [UInt8] = [1, 2, 3]
        do {
            _ = try await udp.send(testData)
            Issue.record("send should throw without connect")
        } catch let error as IO.NonBlocking.Failure {
            switch error {
            case .failure(let leaf):
                #expect(leaf == .notConnected)
            default:
                Issue.record("Expected .failure(.notConnected), got \(error)")
            }
        }

        try await udp.close()
    }

    @Test("recv without connect throws notConnected")
    func recvWithoutConnectThrows() async throws {
        let executor = IO.Executor.Thread()
        let selector = try await IO.NonBlocking.Selector.make(
            driver: IO.NonBlocking.Kqueue.driver(),
            executor: executor
        )
        defer { Task { await selector.shutdown() } }

        var udp = try await IO.NonBlocking.Socket.UDP.unboundIPv4(on: selector)

        var buffer = [UInt8](repeating: 0, count: 32)
        do {
            _ = try await udp.recv(into: &buffer)
            Issue.record("recv should throw without connect")
        } catch let error as IO.NonBlocking.Failure {
            switch error {
            case .failure(let leaf):
                #expect(leaf == .notConnected)
            default:
                Issue.record("Expected .failure(.notConnected), got \(error)")
            }
        }

        try await udp.close()
    }

    @Test("bidirectional connected mode")
    func bidirectionalConnected() async throws {
        let executor = IO.Executor.Thread()
        let selector = try await IO.NonBlocking.Selector.make(
            driver: IO.NonBlocking.Kqueue.driver(),
            executor: executor
        )
        defer { Task { await selector.shutdown() } }

        // Create and bind both sockets
        var alice = try await IO.NonBlocking.Socket.UDP.bind(
            to: .ipv4Loopback(port: 0),
            on: selector
        )
        let alicePort = alice.localAddress!.port!

        var bob = try await IO.NonBlocking.Socket.UDP.bind(
            to: .ipv4Loopback(port: 0),
            on: selector
        )
        let bobPort = bob.localAddress!.port!

        // Connect both to each other
        try alice.connect(to: .ipv4Loopback(port: bobPort))
        try bob.connect(to: .ipv4Loopback(port: alicePort))

        // Alice -> Bob using send()
        let aliceMsg: [UInt8] = Array("from alice".utf8)
        _ = try await alice.send(aliceMsg)

        var bobBuffer = [UInt8](repeating: 0, count: 64)
        let bobRead = try await bob.recv(into: &bobBuffer)
        #expect(Array(bobBuffer[..<bobRead]) == aliceMsg)

        // Bob -> Alice using send()
        let bobMsg: [UInt8] = Array("from bob".utf8)
        _ = try await bob.send(bobMsg)

        var aliceBuffer = [UInt8](repeating: 0, count: 64)
        let aliceRead = try await alice.recv(into: &aliceBuffer)
        #expect(Array(aliceBuffer[..<aliceRead]) == bobMsg)

        try await alice.close()
        try await bob.close()
    }
}
