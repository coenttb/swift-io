//
//  IO.NonBlocking.Socket.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 29/12/2025.
//

@_exported public import IO_NonBlocking

extension IO.NonBlocking {
    /// Socket types for non-blocking network I/O.
    ///
    /// Provides TCP, UDP, and Unix domain socket abstractions built on `Channel`.
    /// All socket types are `~Copyable` (move-only) for proper resource ownership.
    ///
    /// ## Usage
    /// ```swift
    /// // TCP client
    /// let tcp = try await Socket.TCP.connect(to: .ipv4(127, 0, 0, 1, port: 8080), on: selector)
    /// try await tcp.channel.write([72, 101, 108, 108, 111])
    ///
    /// // TCP server
    /// let listener = try await Socket.Listener.bind(to: .ipv4(0, 0, 0, 0, port: 8080), on: selector)
    /// while let client = try await listener.accept() {
    ///     // Handle client...
    /// }
    /// ```
    public enum Socket {}
}
