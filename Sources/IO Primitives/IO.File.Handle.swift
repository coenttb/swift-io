//
//  IO.File.Handle.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 30/12/2025.
//

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif os(Windows)
import WinSDK
#endif

public import Kernel
public import Buffer

extension IO.File {
    /// A move-only file handle with Direct I/O support.
    ///
    /// `IO.File.Handle` owns a file descriptor and stores the resolved
    /// Direct I/O mode and alignment requirements. These are fixed at
    /// open time and cannot be changed.
    ///
    /// ## Direct I/O Invariants
    ///
    /// When `direct == .direct`:
    /// - All read/write operations validate alignment
    /// - Buffer addresses must be aligned to `requirements.bufferAlignment`
    /// - File offsets must be aligned to `requirements.offsetAlignment`
    /// - Transfer lengths must be multiples of `requirements.lengthMultiple`
    ///
    /// When `direct == .uncached` (macOS) or `direct == .buffered`:
    /// - No alignment validation is performed
    /// - Operations use normal page cache semantics
    ///
    /// ## Lifecycle
    ///
    /// The handle closes the descriptor on deinit. For explicit control,
    /// use the `close()` consuming function.
    ///
    /// ## Example
    ///
    /// ```swift
    /// // Open with Direct I/O
    /// var options = IO.File.Open.Options()
    /// options.access = .readWrite
    /// options.cache = .direct
    /// let handle = try IO.File.open(path, options: options)
    ///
    /// // Allocate aligned buffer
    /// var buffer = try Buffer.Aligned(byteCount: 4096, alignment: 4096)
    ///
    /// // Read with automatic alignment validation
    /// let bytesRead = try handle.read(into: &buffer, at: 0)
    /// ```
    public struct Handle: ~Copyable, @unchecked Sendable {
        /// The underlying file descriptor.
        @usableFromInline
        let descriptor: IO.File.Descriptor

        /// The resolved Direct I/O mode (fixed at open time).
        public let direct: IO.File.Direct.Mode.Resolved

        /// The alignment requirements (fixed at open time).
        ///
        /// For `.direct` mode, this is always `.known(...)`.
        /// For `.uncached` or `.buffered`, this may be `.unknown(...)`.
        public let requirements: IO.File.Direct.Requirements

        /// Creates a handle from a descriptor with Direct I/O state.
        ///
        /// - Parameters:
        ///   - descriptor: The file descriptor (ownership transferred).
        ///   - direct: The resolved Direct I/O mode.
        ///   - requirements: The alignment requirements.
        @usableFromInline
        init(
            descriptor: IO.File.Descriptor,
            direct: IO.File.Direct.Mode.Resolved,
            requirements: IO.File.Direct.Requirements
        ) {
            self.descriptor = descriptor
            self.direct = direct
            self.requirements = requirements
        }

        deinit {
            try? Kernel.Close.close(descriptor)
        }
    }
}

// MARK: - Read

extension IO.File.Handle {
    /// Reads from the file at a specific offset.
    ///
    /// For Direct I/O handles, this validates alignment before the syscall.
    ///
    /// - Parameters:
    ///   - buffer: The buffer to read into.
    ///   - offset: The file offset to read from.
    /// - Returns: The number of bytes read.
    /// - Throws: `Kernel.Read.Error` on failure.
    public func read(
        into buffer: UnsafeMutableRawBufferPointer,
        at offset: Int64
    ) throws(Kernel.Read.Error) -> Int {
        try Kernel.Read.pread(descriptor, into: buffer, at: offset)
    }

    /// Reads from the file at a specific offset into an aligned buffer.
    ///
    /// - Parameters:
    ///   - buffer: The aligned buffer to read into.
    ///   - offset: The file offset to read from.
    /// - Returns: The number of bytes read.
    /// - Throws: `Kernel.Read.Error` on failure.
    public func read(
        into buffer: inout Buffer.Aligned,
        at offset: Int64
    ) throws(Kernel.Read.Error) -> Int {
        try buffer.withUnsafeMutableBytes { (ptr: UnsafeMutableRawBufferPointer) throws(Kernel.Read.Error) -> Int in
            try read(into: ptr, at: offset)
        }
    }
}

// MARK: - Write

extension IO.File.Handle {
    /// Writes to the file at a specific offset.
    ///
    /// - Parameters:
    ///   - buffer: The buffer to write from.
    ///   - offset: The file offset to write at.
    /// - Returns: The number of bytes written.
    /// - Throws: `Kernel.Write.Error` on failure.
    public func write(
        from buffer: UnsafeRawBufferPointer,
        at offset: Int64
    ) throws(Kernel.Write.Error) -> Int {
        try Kernel.Write.pwrite(descriptor, from: buffer, at: offset)
    }

    /// Writes to the file at a specific offset from an aligned buffer.
    ///
    /// - Parameters:
    ///   - buffer: The aligned buffer to write from.
    ///   - offset: The file offset to write at.
    /// - Returns: The number of bytes written.
    /// - Throws: `Kernel.Write.Error` on failure.
    public func write(
        from buffer: borrowing Buffer.Aligned,
        at offset: Int64
    ) throws(Kernel.Write.Error) -> Int {
        try buffer.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) throws(Kernel.Write.Error) -> Int in
            try write(from: ptr, at: offset)
        }
    }
}

// MARK: - Alignment Validation

extension IO.File.Handle {
    /// Validates alignment requirements for Direct I/O.
    ///
    /// - Parameters:
    ///   - buffer: The buffer address.
    ///   - offset: The file offset.
    ///   - length: The transfer length.
    /// - Throws: `IO.File.Handle.Error` on alignment violation.
    private func validateAlignment(
        buffer: UnsafeRawPointer,
        offset: Int64,
        length: Int
    ) throws(Error) {
        guard case .known(let alignment) = requirements else {
            throw .requirementsUnknown
        }

        if let directError = alignment.validate(buffer: buffer, offset: offset, length: length) {
            throw Error(from: directError)
        }
    }
}

// MARK: - Close

extension IO.File.Handle {
    /// Closes the file handle explicitly.
    ///
    /// After calling this method, the handle is consumed and cannot be used.
    /// The descriptor is closed regardless of whether the close syscall succeeds.
    public consuming func close() {
        try? Kernel.Close.close(descriptor)
    }
}

// MARK: - Descriptor Access

extension IO.File.Handle {
    /// Provides scoped access to the raw descriptor.
    ///
    /// Use this only when you need to pass the descriptor to other APIs.
    /// Do not close the descriptor within the closure.
    ///
    /// - Parameter body: A closure that receives the descriptor.
    /// - Returns: The value returned by `body`.
    @inlinable
    public func withDescriptor<T>(
        _ body: (IO.File.Descriptor) throws -> T
    ) rethrows -> T {
        try body(descriptor)
    }
}
