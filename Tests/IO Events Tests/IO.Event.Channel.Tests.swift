//
//  IO.Event.Channel.Tests.swift
//  swift-io
//

import IO_Events_Kqueue
import Kernel
import StandardsTestSupport
import Testing

@testable import IO_Events

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

extension IO.Event.Channel {
    #TestSuites
}

// MARK: - Basic I/O Tests

extension IO.Event.Channel.Test {
    @Suite struct BasicIO {}
}

extension IO.Event.Channel.Test.BasicIO {
    /// Helper to create a non-blocking pipe
    private static func makeNonBlockingPipe() throws -> (read: Int32, write: Int32) {
        var fds: (Int32, Int32) = (0, 0)
        let result = withUnsafeMutablePointer(to: &fds) { ptr in
            ptr.withMemoryRebound(to: Int32.self, capacity: 2) { pipe($0) }
        }
        guard result == 0 else {
            throw IO.Event.Error.platform(.posix(errno))
        }

        // Set non-blocking mode
        var flags = fcntl(fds.0, F_GETFL)
        _ = fcntl(fds.0, F_SETFL, flags | O_NONBLOCK)
        flags = fcntl(fds.1, F_GETFL)
        _ = fcntl(fds.1, F_SETFL, flags | O_NONBLOCK)

        return fds
    }

    @Test("read returns data written to pipe")
    func readReturnsWrittenData() async throws {
        let executor = IO.Executor.Thread()
        let selector = try await IO.Event.Selector.make(
            driver: IO.Event.Kqueue.driver(),
            executor: executor
        )

        let pipe = try Self.makeNonBlockingPipe()
        defer {
            close(pipe.read)
            close(pipe.write)
        }

        // Write some data to the pipe
        let testData: [UInt8] = [1, 2, 3, 4, 5]
        _ = Darwin.write(pipe.write, testData, testData.count)

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
        let executor = IO.Executor.Thread()
        let selector = try await IO.Event.Selector.make(
            driver: IO.Event.Kqueue.driver(),
            executor: executor
        )

        let pipe = try Self.makeNonBlockingPipe()
        defer {
            close(pipe.read)
            close(pipe.write)
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
        let bytesRead = Darwin.read(pipe.read, &buffer, buffer.count)

        #expect(bytesRead == 5)
        #expect(Array(buffer[..<bytesRead]) == testData)

        // Clean up
        try await channel.close()
        await selector.shutdown()
    }

    @Test("zero-capacity buffer returns 0 without EOF")
    func zeroCapacityBufferReturnsZero() async throws {
        let executor = IO.Executor.Thread()
        let selector = try await IO.Event.Selector.make(
            driver: IO.Event.Kqueue.driver(),
            executor: executor
        )

        let pipe = try Self.makeNonBlockingPipe()
        defer {
            close(pipe.read)
            close(pipe.write)
        }

        // Write some data so EOF isn't expected
        _ = Darwin.write(pipe.write, [UInt8]([1, 2, 3]), 3)

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
        let executor = IO.Executor.Thread()
        let selector = try await IO.Event.Selector.make(
            driver: IO.Event.Kqueue.driver(),
            executor: executor
        )

        let pipe = try Self.makeNonBlockingPipe()
        defer {
            close(pipe.read)
            close(pipe.write)
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
    /// Helper to create a non-blocking pipe
    private static func makeNonBlockingPipe() throws -> (read: Int32, write: Int32) {
        var fds: (Int32, Int32) = (0, 0)
        let result = withUnsafeMutablePointer(to: &fds) { ptr in
            ptr.withMemoryRebound(to: Int32.self, capacity: 2) { pipe($0) }
        }
        guard result == 0 else {
            throw IO.Event.Error.platform(.posix(errno))
        }

        // Set non-blocking mode
        var flags = fcntl(fds.0, F_GETFL)
        _ = fcntl(fds.0, F_SETFL, flags | O_NONBLOCK)
        flags = fcntl(fds.1, F_GETFL)
        _ = fcntl(fds.1, F_SETFL, flags | O_NONBLOCK)

        return fds
    }

    @Test("read returns 0 on EOF (peer closed)")
    func readReturnsZeroOnEOF() async throws {
        let executor = IO.Executor.Thread()
        let selector = try await IO.Event.Selector.make(
            driver: IO.Event.Kqueue.driver(),
            executor: executor
        )

        let pipe = try Self.makeNonBlockingPipe()
        defer {
            close(pipe.read)
        }

        // Close write end to signal EOF
        close(pipe.write)

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
    /// Helper to create a non-blocking socket pair
    private static func makeNonBlockingSocketPair() throws -> (Int32, Int32) {
        var fds: (Int32, Int32) = (0, 0)
        let result = withUnsafeMutablePointer(to: &fds) { ptr in
            ptr.withMemoryRebound(to: Int32.self, capacity: 2) {
                socketpair(AF_UNIX, SOCK_STREAM, 0, $0)
            }
        }
        guard result == 0 else {
            throw IO.Event.Error.platform(.posix(errno))
        }

        // Set non-blocking mode
        var flags = fcntl(fds.0, F_GETFL)
        _ = fcntl(fds.0, F_SETFL, flags | O_NONBLOCK)
        flags = fcntl(fds.1, F_GETFL)
        _ = fcntl(fds.1, F_SETFL, flags | O_NONBLOCK)

        return fds
    }

    @Test("shutdownRead is idempotent")
    func shutdownReadIdempotent() async throws {
        let executor = IO.Executor.Thread()
        let selector = try await IO.Event.Selector.make(
            driver: IO.Event.Kqueue.driver(),
            executor: executor
        )

        let sockets = try Self.makeNonBlockingSocketPair()
        defer {
            close(sockets.0)
            close(sockets.1)
        }

        var channel = try await IO.Event.Channel.wrap(
            sockets.0,
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
        let executor = IO.Executor.Thread()
        let selector = try await IO.Event.Selector.make(
            driver: IO.Event.Kqueue.driver(),
            executor: executor
        )

        let sockets = try Self.makeNonBlockingSocketPair()
        defer {
            close(sockets.0)
            close(sockets.1)
        }

        var channel = try await IO.Event.Channel.wrap(
            sockets.0,
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
        } catch let error as IO.Event.Failure {
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
    /// Helper to create a non-blocking pipe
    private static func makeNonBlockingPipe() throws -> (read: Int32, write: Int32) {
        var fds: (Int32, Int32) = (0, 0)
        let result = withUnsafeMutablePointer(to: &fds) { ptr in
            ptr.withMemoryRebound(to: Int32.self, capacity: 2) { pipe($0) }
        }
        guard result == 0 else {
            throw IO.Event.Error.platform(.posix(errno))
        }

        // Set non-blocking mode
        var flags = fcntl(fds.0, F_GETFL)
        _ = fcntl(fds.0, F_SETFL, flags | O_NONBLOCK)
        flags = fcntl(fds.1, F_GETFL)
        _ = fcntl(fds.1, F_SETFL, flags | O_NONBLOCK)

        return fds
    }

    @Test("close deregisters from selector")
    func closeDeregisters() async throws {
        let executor = IO.Executor.Thread()
        let selector = try await IO.Event.Selector.make(
            driver: IO.Event.Kqueue.driver(),
            executor: executor
        )

        let pipe = try Self.makeNonBlockingPipe()
        defer {
            // Pipe read end will be closed by channel
            close(pipe.write)
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
