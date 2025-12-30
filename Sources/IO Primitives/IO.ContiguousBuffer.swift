//
//  IO.ContiguousBuffer.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 28/12/2025.
//

extension IO {
    /// Read-only contiguous buffer capability.
    ///
    /// Types conforming to this protocol provide access to a contiguous
    /// region of bytes that can be read. This protocol is designed to be
    /// async-safe: the raw pointer is only valid within the closure scope,
    /// avoiding lifetime issues across suspension points.
    ///
    /// ## Usage
    /// ```swift
    /// func write<B: IO.ContiguousBuffer>(_ buffer: B) async throws -> Int {
    ///     // Wait for readiness (no pointers in scope)
    ///     try await awaitWriteReady()
    ///
    ///     // Create pointer only in synchronous region
    ///     return buffer.withUnsafeBytes { ptr in
    ///         performWrite(ptr)  // No awaits here
    ///     }
    /// }
    /// ```
    ///
    /// ## Conformances
    /// Standard library types conform automatically:
    /// - `Array<UInt8>`
    /// - `ContiguousArray<UInt8>`
    public protocol ContiguousBuffer {
        /// Calls the given closure with a pointer to the buffer's contiguous bytes.
        ///
        /// - Parameter body: A closure that receives the raw buffer pointer.
        /// - Returns: The value returned by the closure.
        /// - Throws: Any error thrown by the closure.
        func withUnsafeBytes<R>(
            _ body: (UnsafeRawBufferPointer) throws -> R
        ) rethrows -> R
    }

    /// Mutable contiguous buffer capability.
    ///
    /// Types conforming to this protocol provide mutable access to a contiguous
    /// region of bytes. This protocol is designed to be async-safe: the raw
    /// pointer is only valid within the closure scope.
    ///
    /// ## Usage
    /// ```swift
    /// func read<B: IO.ContiguousMutableBuffer>(into buffer: inout B) async throws -> Int {
    ///     // Wait for readiness (no pointers in scope)
    ///     try await awaitReadReady()
    ///
    ///     // Create pointer only in synchronous region
    ///     return buffer.withUnsafeMutableBytes { ptr in
    ///         performRead(into: ptr)  // No awaits here
    ///     }
    /// }
    /// ```
    public protocol ContiguousMutableBuffer {
        /// Calls the given closure with a mutable pointer to the buffer's bytes.
        ///
        /// - Parameter body: A closure that receives the mutable raw buffer pointer.
        /// - Returns: The value returned by the closure.
        /// - Throws: Any error thrown by the closure.
        mutating func withUnsafeMutableBytes<R>(
            _ body: (UnsafeMutableRawBufferPointer) throws -> R
        ) rethrows -> R
    }
}

// MARK: - Array Conformances

extension Array: IO.ContiguousBuffer where Element == UInt8 {
    public func withUnsafeBytes<R>(
        _ body: (UnsafeRawBufferPointer) throws -> R
    ) rethrows -> R {
        try self.withUnsafeBufferPointer { bufferPtr in
            try body(UnsafeRawBufferPointer(bufferPtr))
        }
    }
}

extension Array: IO.ContiguousMutableBuffer where Element == UInt8 {
    public mutating func withUnsafeMutableBytes<R>(
        _ body: (UnsafeMutableRawBufferPointer) throws -> R
    ) rethrows -> R {
        try self.withUnsafeMutableBufferPointer { bufferPtr in
            try body(UnsafeMutableRawBufferPointer(bufferPtr))
        }
    }
}

// MARK: - ContiguousArray Conformances

extension ContiguousArray: IO.ContiguousBuffer where Element == UInt8 {
    public func withUnsafeBytes<R>(
        _ body: (UnsafeRawBufferPointer) throws -> R
    ) rethrows -> R {
        try self.withUnsafeBufferPointer { bufferPtr in
            try body(UnsafeRawBufferPointer(bufferPtr))
        }
    }
}

extension ContiguousArray: IO.ContiguousMutableBuffer where Element == UInt8 {
    public mutating func withUnsafeMutableBytes<R>(
        _ body: (UnsafeMutableRawBufferPointer) throws -> R
    ) rethrows -> R {
        try self.withUnsafeMutableBufferPointer { bufferPtr in
            try body(UnsafeMutableRawBufferPointer(bufferPtr))
        }
    }
}
