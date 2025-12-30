//
//  IO.Syscalls.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 30/12/2025.
//
//  Span adapters for Kernel syscalls.
//
//  Per ARCHITECTURE.md, Kernel uses raw pointers while swift-io
//  provides Span-first ergonomics for higher-level code.
//

public import Kernel

extension IO {
    /// Span-based syscall adapters.
    ///
    /// These provide ergonomic wrappers around Kernel syscalls
    /// that accept `Span` and `MutableSpan` instead of raw pointers.
    public enum Syscalls {}
}

// MARK: - Read Operations

extension IO.Syscalls {
    /// Reads bytes from a file descriptor into a mutable span.
    ///
    /// - Parameters:
    ///   - descriptor: The file descriptor to read from.
    ///   - span: The mutable span to read into.
    /// - Returns: Number of bytes read. Returns 0 on EOF.
    /// - Throws: `Kernel.Read.Error` on failure.
    @inlinable
    public static func read(
        _ descriptor: Kernel.Descriptor,
        into span: inout MutableSpan<UInt8>
    ) throws(Kernel.Read.Error) -> Int {
        try span.withUnsafeMutableBytes { (buffer: UnsafeMutableRawBufferPointer) throws(Kernel.Read.Error) -> Int in
            try Kernel.Read.read(descriptor, into: buffer)
        }
    }

    /// Reads bytes from a file descriptor at a specific offset.
    ///
    /// - Parameters:
    ///   - descriptor: The file descriptor to read from.
    ///   - span: The mutable span to read into.
    ///   - offset: The file offset to read from.
    /// - Returns: Number of bytes read. Returns 0 on EOF.
    /// - Throws: `Kernel.Read.Error` on failure.
    @inlinable
    public static func pread(
        _ descriptor: Kernel.Descriptor,
        into span: inout MutableSpan<UInt8>,
        at offset: Int64
    ) throws(Kernel.Read.Error) -> Int {
        try span.withUnsafeMutableBytes { (buffer: UnsafeMutableRawBufferPointer) throws(Kernel.Read.Error) -> Int in
            try Kernel.Read.pread(descriptor, into: buffer, at: offset)
        }
    }
}

// MARK: - Write Operations

extension IO.Syscalls {
    /// Writes bytes from a span to a file descriptor.
    ///
    /// - Parameters:
    ///   - descriptor: The file descriptor to write to.
    ///   - span: The span containing bytes to write.
    /// - Returns: Number of bytes written.
    /// - Throws: `Kernel.Write.Error` on failure.
    @inlinable
    public static func write(
        _ descriptor: Kernel.Descriptor,
        from span: Span<UInt8>
    ) throws(Kernel.Write.Error) -> Int {
        try span.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) throws(Kernel.Write.Error) -> Int in
            try Kernel.Write.write(descriptor, from: buffer)
        }
    }

    /// Writes bytes from a span to a file descriptor at a specific offset.
    ///
    /// - Parameters:
    ///   - descriptor: The file descriptor to write to.
    ///   - span: The span containing bytes to write.
    ///   - offset: The file offset to write at.
    /// - Returns: Number of bytes written.
    /// - Throws: `Kernel.Write.Error` on failure.
    @inlinable
    public static func pwrite(
        _ descriptor: Kernel.Descriptor,
        from span: Span<UInt8>,
        at offset: Int64
    ) throws(Kernel.Write.Error) -> Int {
        try span.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) throws(Kernel.Write.Error) -> Int in
            try Kernel.Write.pwrite(descriptor, from: buffer, at: offset)
        }
    }
}
