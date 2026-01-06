//
//  IO.Event.Channel.Tests.swift
//  swift-io
//

import IO_Events
import Kernel
import StandardsTestSupport
import Testing

@testable import IO_Events

extension IO.Event.Channel {
    #TestSuites
}

// MARK: - Basic I/O Tests

extension IO.Event.Channel.Test {
    @Suite struct BasicIO {}
}

extension IO.Event.Channel.Test.BasicIO {
    /// Helper to create a non-blocking pipe using swift-kernel APIs
    private static func makeNonBlockingPipe() throws -> (read: Kernel.Descriptor, write: Kernel.Descriptor) {
        let pipe = try Kernel.Pipe.create()
        try Kernel.File.Control.setNonBlocking(pipe.read)
        try Kernel.File.Control.setNonBlocking(pipe.write)
        return pipe
    }

    @Test("read returns data written to pipe")
    func readReturnsWrittenData() async throws {
        let executor = Kernel.Thread.Executor()
        let selector = try await IO.Event.Selector.make(
            driver: IO.Event.Kqueue.driver(),
            executor: executor
        )

        let pipe = try Self.makeNonBlockingPipe()
        defer {
            try? Kernel.Close.close(pipe.read)
            try? Kernel.Close.close(pipe.write)
        }

        // Write some data to the pipe
        let testData: [UInt8] = [1, 2, 3, 4, 5]
        try testData.withUnsafeBytes { buffer in
            _ = try Kernel.IO.Write.write(pipe.write, from: buffer)
        }

        // Create channel for reading
        var channel = try await IO.Event.Channel.wrap(
            pipe.read,
            selector: selector,
            interest: .read
        )

        // Read the data
        var buffer = [UInt8](repeating: 0, count: 10)
        let bytesRead = try await channel.read(into: &buffer)

        #expect(bytesRead == 5)
        #expect(Array(buffer[..<bytesRead]) == testData)

        // Clean up
        try await channel.close()
        await selector.shutdown()
    }

    @Test("write sends data through pipe")
    func writeSendsData() async throws {
        let executor = Kernel.Thread.Executor()
        let selector = try await IO.Event.Selector.make(
            driver: IO.Event.Kqueue.driver(),
            executor: executor
        )

        let pipe = try Self.makeNonBlockingPipe()
        defer {
            try? Kernel.Close.close(pipe.read)
            try? Kernel.Close.close(pipe.write)
        }

        // Create channel for writing
        var channel = try await IO.Event.Channel.wrap(
            pipe.write,
            selector: selector,
            interest: .write
        )

        // Write data
        let testData: [UInt8] = [10, 20, 30, 40, 50]
        let bytesWritten = try await channel.write(testData)

        #expect(bytesWritten == 5)

        // Read from the other end to verify
        var buffer = [UInt8](repeating: 0, count: 10)
        let bytesRead = try buffer.withUnsafeMutableBytes { buf in
            try Kernel.IO.Read.read(pipe.read, into: buf)
        }

        #expect(bytesRead == 5)
        #expect(Array(buffer[..<bytesRead]) == testData)

        // Clean up
        try await channel.close()
        await selector.shutdown()
    }

    @Test("zero-capacity buffer returns 0 without EOF")
    func zeroCapacityBufferReturnsZero() async throws {
        let executor = Kernel.Thread.Executor()
        let selector = try await IO.Event.Selector.make(
            driver: IO.Event.Kqueue.driver(),
            executor: executor
        )

        let pipe = try Self.makeNonBlockingPipe()
        defer {
            try? Kernel.Close.close(pipe.read)
            try? Kernel.Close.close(pipe.write)
        }

        // Write some data so EOF isn't expected
        let writeData: [UInt8] = [1, 2, 3]
        try writeData.withUnsafeBytes { buffer in
            _ = try Kernel.IO.Write.write(pipe.write, from: buffer)
        }

        var channel = try await IO.Event.Channel.wrap(
            pipe.read,
            selector: selector,
            interest: .read
        )

        // Read with zero-capacity buffer
        var emptyBuffer = [UInt8]()
        let bytesRead = try await channel.read(into: &emptyBuffer)

        #expect(bytesRead == 0)

        // Verify we can still read actual data (not EOF)
        var realBuffer = [UInt8](repeating: 0, count: 10)
        let actualBytesRead = try await channel.read(into: &realBuffer)
        #expect(actualBytesRead == 3)

        try await channel.close()
        await selector.shutdown()
    }

    @Test("zero-length write returns 0")
    func zeroLengthWriteReturnsZero() async throws {
        let executor = Kernel.Thread.Executor()
        let selector = try await IO.Event.Selector.make(
            driver: IO.Event.Kqueue.driver(),
            executor: executor
        )

        let pipe = try Self.makeNonBlockingPipe()
        defer {
            try? Kernel.Close.close(pipe.read)
            try? Kernel.Close.close(pipe.write)
        }

        var channel = try await IO.Event.Channel.wrap(
            pipe.write,
            selector: selector,
            interest: .write
        )

        // Write empty buffer
        let emptyBuffer = [UInt8]()
        let bytesWritten = try await channel.write(emptyBuffer)

        #expect(bytesWritten == 0)

        try await channel.close()
        await selector.shutdown()
    }
}

// MARK: - EOF Tests

extension IO.Event.Channel.Test {
    @Suite struct EOF {}
}

extension IO.Event.Channel.Test.EOF {
    /// Helper to create a non-blocking pipe using swift-kernel APIs
    private static func makeNonBlockingPipe() throws -> (read: Kernel.Descriptor, write: Kernel.Descriptor) {
        let pipe = try Kernel.Pipe.create()
        try Kernel.File.Control.setNonBlocking(pipe.read)
        try Kernel.File.Control.setNonBlocking(pipe.write)
        return pipe
    }

    @Test("read returns 0 on EOF (peer closed)")
    func readReturnsZeroOnEOF() async throws {
        let executor = Kernel.Thread.Executor()
        let selector = try await IO.Event.Selector.make(
            driver: IO.Event.Kqueue.driver(),
            executor: executor
        )

        let pipe = try Self.makeNonBlockingPipe()
        defer {
            try? Kernel.Close.close(pipe.read)
        }

        // Close write end to signal EOF
        try Kernel.Close.close(pipe.write)

        var channel = try await IO.Event.Channel.wrap(
            pipe.read,
            selector: selector,
            interest: .read
        )

        // Read should return 0 (EOF)
        var buffer = [UInt8](repeating: 0, count: 10)
        let bytesRead = try await channel.read(into: &buffer)

        #expect(bytesRead == 0)

        // Subsequent reads should also return 0
        let bytesRead2 = try await channel.read(into: &buffer)
        #expect(bytesRead2 == 0)

        try await channel.close()
        await selector.shutdown()
    }
}

// MARK: - Half-Close Tests

extension IO.Event.Channel.Test {
    @Suite struct HalfClose {}
}

extension IO.Event.Channel.Test.HalfClose {
    /// Helper to create a non-blocking socket pair using swift-kernel APIs
    private static func makeNonBlockingSocketPair() throws -> (Kernel.Socket.Descriptor, Kernel.Socket.Descriptor) {
        let sockets = try Kernel.Socket.Pair.create()
        try Kernel.File.Control.setNonBlocking(Kernel.Descriptor(rawValue: sockets.0.rawValue))
        try Kernel.File.Control.setNonBlocking(Kernel.Descriptor(rawValue: sockets.1.rawValue))
        return sockets
    }

    @Test("shutdownRead is idempotent")
    func shutdownReadIdempotent() async throws {
        let executor = Kernel.Thread.Executor()
        let selector = try await IO.Event.Selector.make(
            driver: IO.Event.Kqueue.driver(),
            executor: executor
        )

        let sockets = try Self.makeNonBlockingSocketPair()
        defer {
            try? Kernel.Close.close(Kernel.Descriptor(rawValue: sockets.0.rawValue))
            try? Kernel.Close.close(Kernel.Descriptor(rawValue: sockets.1.rawValue))
        }

        var channel = try await IO.Event.Channel.wrap(
            Kernel.Descriptor(rawValue: sockets.0.rawValue),
            selector: selector,
            interest: .read
        )

        // First shutdown should succeed
        try await channel.shutdownRead()

        // Second shutdown should be a no-op (idempotent)
        try await channel.shutdownRead()

        // Reads should return 0 after shutdown
        var buffer = [UInt8](repeating: 0, count: 10)
        let bytesRead = try await channel.read(into: &buffer)
        #expect(bytesRead == 0)

        try await channel.close()
        await selector.shutdown()
    }

    @Test("shutdownWrite is idempotent")
    func shutdownWriteIdempotent() async throws {
        let executor = Kernel.Thread.Executor()
        let selector = try await IO.Event.Selector.make(
            driver: IO.Event.Kqueue.driver(),
            executor: executor
        )

        let sockets = try Self.makeNonBlockingSocketPair()
        defer {
            try? Kernel.Close.close(Kernel.Descriptor(rawValue: sockets.0.rawValue))
            try? Kernel.Close.close(Kernel.Descriptor(rawValue: sockets.1.rawValue))
        }

        var channel = try await IO.Event.Channel.wrap(
            Kernel.Descriptor(rawValue: sockets.0.rawValue),
            selector: selector,
            interest: .write
        )

        // First shutdown should succeed
        try await channel.shutdownWrite()

        // Second shutdown should be a no-op (idempotent)
        try await channel.shutdownWrite()

        // Writes should throw after shutdown
        let testData: [UInt8] = [1, 2, 3]
        do {
            _ = try await channel.write(testData)
            Issue.record("write should throw after shutdownWrite")
        } catch {
            switch error {
            case .failure(let leaf):
                switch leaf {
                case .writeClosed:
                    break  // Expected
                default:
                    Issue.record("Expected writeClosed, got \(leaf)")
                }
            default:
                Issue.record("Expected .failure(.writeClosed), got \(error)")
            }
        }

        try await channel.close()
        await selector.shutdown()
    }
}

// MARK: - Close Tests

extension IO.Event.Channel.Test {
    @Suite struct Close {}
}

extension IO.Event.Channel.Test.Close {
    /// Helper to create a non-blocking pipe using swift-kernel APIs
    private static func makeNonBlockingPipe() throws -> (read: Kernel.Descriptor, write: Kernel.Descriptor) {
        let pipe = try Kernel.Pipe.create()
        try Kernel.File.Control.setNonBlocking(pipe.read)
        try Kernel.File.Control.setNonBlocking(pipe.write)
        return pipe
    }

    @Test("close deregisters from selector")
    func closeDeregisters() async throws {
        let executor = Kernel.Thread.Executor()
        let selector = try await IO.Event.Selector.make(
            driver: IO.Event.Kqueue.driver(),
            executor: executor
        )

        let pipe = try Self.makeNonBlockingPipe()
        defer {
            // Pipe read end will be closed by channel
            try? Kernel.Close.close(pipe.write)
        }

        var channel = try await IO.Event.Channel.wrap(
            pipe.read,
            selector: selector,
            interest: .read
        )

        // Close should succeed
        try await channel.close()

        // Selector should still work for other operations
        await selector.shutdown()
    }
}
