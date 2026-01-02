//
//  Fixtures.swift
//  swift-io
//
//  Shared fixtures for non-blocking I/O benchmarks.
//

import IO_Events_Kqueue

@testable import IO_Events

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

/// Shared fixture providing a pre-configured selector for benchmarks.
///
/// Creates pipes for realistic I/O operations and provides
/// helper methods for common benchmark patterns.
final class SelectorFixture: @unchecked Sendable {
    let selector: IO.Event.Selector
    let executor: IO.Executor.Thread

    /// Creates a new selector fixture.
    /// - Throws: If selector creation fails.
    static func make() async throws -> SelectorFixture {
        let executor = IO.Executor.Thread()
        let selector = try await IO.Event.Selector.make(
            driver: IO.Event.Kqueue.driver(),
            executor: executor
        )
        return SelectorFixture(selector: selector, executor: executor)
    }

    private init(selector: IO.Event.Selector, executor: IO.Executor.Thread) {
        self.selector = selector
        self.executor = executor
    }

    /// Creates a pipe and returns (read fd, write fd).
    func createPipe() throws -> (Int32, Int32) {
        var fds: (Int32, Int32) = (0, 0)
        let result = withUnsafeMutablePointer(to: &fds) { ptr in
            ptr.withMemoryRebound(to: Int32.self, capacity: 2) { pipe($0) }
        }
        guard result == 0 else {
            throw IO.Event.Error.platform(errno: errno)
        }
        return fds
    }

    /// Closes a file descriptor.
    func closeFD(_ fd: Int32) {
        close(fd)
    }

    /// Shuts down the selector.
    func shutdown() async {
        await selector.shutdown()
    }
}
