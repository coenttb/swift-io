//
//  IO.Buffer.Aligned.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 30/12/2025.
//

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif os(Windows)
import ucrt
import WinSDK
#endif

extension IO.Buffer {
    /// A move-only buffer with guaranteed memory alignment.
    ///
    /// Direct I/O operations require buffers aligned to specific boundaries
    /// (typically sector size: 512 or 4096 bytes). This type provides:
    ///
    /// - Portable aligned allocation across platforms
    /// - Move-only semantics to prevent accidental copying
    /// - Automatic deallocation on scope exit
    ///
    /// ## Platform Implementation
    ///
    /// | Platform | Allocation | Deallocation |
    /// |----------|------------|--------------|
    /// | POSIX | `posix_memalign` | `free` |
    /// | Windows | `_aligned_malloc` | `_aligned_free` |
    ///
    /// ## Usage
    ///
    /// ```swift
    /// // Allocate a 4KB buffer aligned to 4096 bytes
    /// var buffer = try IO.Buffer.Aligned(byteCount: 4096, alignment: 4096)
    ///
    /// // Write data into the buffer
    /// buffer.withUnsafeMutableBytes { ptr in
    ///     ptr.copyBytes(from: data)
    /// }
    ///
    /// // Use with Direct I/O
    /// try handle.read(into: &buffer, at: 0)
    /// ```
    ///
    /// ## Alignment Verification
    ///
    /// ```swift
    /// let buffer = try IO.Buffer.Aligned(byteCount: 4096, alignment: 512)
    /// assert(buffer.isAligned(to: 512))  // true
    /// assert(buffer.isAligned(to: 4096)) // may be true (depends on allocator)
    /// ```
    public struct Aligned: ~Copyable, @unchecked Sendable {
        /// The underlying memory pointer.
        private var pointer: UnsafeMutableRawPointer

        /// The number of bytes allocated.
        public let count: Int

        /// The alignment of the allocation.
        public let alignment: Int

        /// Creates an aligned buffer with uninitialized contents.
        ///
        /// - Parameters:
        ///   - byteCount: The number of bytes to allocate.
        ///   - alignment: The alignment boundary (must be a power of 2).
        /// - Throws: `Error.allocationFailed` if allocation fails.
        public init(byteCount: Int, alignment: Int) throws(Error) {
            guard byteCount > 0 else {
                throw .invalidSize
            }
            guard alignment > 0 && alignment.nonzeroBitCount == 1 else {
                throw .invalidAlignment
            }

            #if os(Windows)
            guard let ptr = _aligned_malloc(byteCount, alignment) else {
                throw .allocationFailed
            }
            self.pointer = ptr
            #else
            var ptr: UnsafeMutableRawPointer?
            let result = posix_memalign(&ptr, alignment, byteCount)
            guard result == 0, let allocated = ptr else {
                throw .allocationFailed
            }
            self.pointer = allocated
            #endif

            self.count = byteCount
            self.alignment = alignment
        }

        /// Creates an aligned buffer initialized with zeros.
        ///
        /// - Parameters:
        ///   - byteCount: The number of bytes to allocate.
        ///   - alignment: The alignment boundary (must be a power of 2).
        /// - Throws: `Error.allocationFailed` if allocation fails.
        public static func zeroed(
            byteCount: Int,
            alignment: Int
        ) throws(Error) -> Self {
            let buffer = try Self(byteCount: byteCount, alignment: alignment)
            buffer.pointer.initializeMemory(as: UInt8.self, repeating: 0, count: byteCount)
            return buffer
        }

        deinit {
            #if os(Windows)
            _aligned_free(pointer)
            #else
            free(pointer)
            #endif
        }
    }
}

// MARK: - Memory Access

extension IO.Buffer.Aligned {
    /// Provides read-only access to the buffer contents.
    ///
    /// - Parameter body: A closure that receives a pointer to the buffer.
    /// - Returns: The value returned by `body`.
    public func withUnsafeBytes<T>(
        _ body: (UnsafeRawBufferPointer) throws -> T
    ) rethrows -> T {
        try body(UnsafeRawBufferPointer(start: pointer, count: count))
    }

    /// Provides read-write access to the buffer contents.
    ///
    /// - Parameter body: A closure that receives a mutable pointer to the buffer.
    /// - Returns: The value returned by `body`.
    public mutating func withUnsafeMutableBytes<T>(
        _ body: (UnsafeMutableRawBufferPointer) throws -> T
    ) rethrows -> T {
        try body(UnsafeMutableRawBufferPointer(start: pointer, count: count))
    }

    /// The base address of the buffer (read-only).
    ///
    /// Use `withUnsafeBytes` or `withUnsafeMutableBytes` for safe access.
    /// This property is provided for cases where you need just the address.
    public var baseAddress: UnsafeRawPointer {
        UnsafeRawPointer(pointer)
    }

    /// The mutable base address of the buffer.
    ///
    /// **This is an unsafe escape hatch.** Use `withUnsafeMutableBytes` when possible.
    ///
    /// This property is provided for performance-critical code and cases where
    /// typed throws prevent using `withUnsafeMutableBytes` closures.
    ///
    /// ## Safety Requirements
    ///
    /// - The pointer is only valid for the lifetime of this buffer
    /// - Do not store the pointer beyond the scope where the buffer is live
    /// - Do not assume alignment beyond `self.alignment`
    /// - The caller is responsible for bounds checking (`count` bytes available)
    public var mutableBaseAddress: UnsafeMutableRawPointer {
        pointer
    }
}

// MARK: - Alignment Verification

extension IO.Buffer.Aligned {
    /// Checks if the buffer is aligned to the given boundary.
    ///
    /// The buffer is always aligned to at least `self.alignment`.
    /// It may also be aligned to larger powers of 2 depending on
    /// the underlying allocator.
    ///
    /// - Parameter boundary: The alignment to check.
    /// - Returns: `true` if aligned.
    public func isAligned(to boundary: Int) -> Bool {
        guard boundary > 0 && boundary.nonzeroBitCount == 1 else {
            return false
        }
        return Int(bitPattern: pointer) % boundary == 0
    }
}

// MARK: - Error

extension IO.Buffer.Aligned {
    /// Errors that can occur during aligned buffer operations.
    public enum Error: Swift.Error, Sendable, Equatable {
        /// The requested size is invalid (zero or negative).
        case invalidSize

        /// The requested alignment is invalid (not a power of 2).
        case invalidAlignment

        /// Memory allocation failed.
        case allocationFailed
    }
}

// MARK: - Test Helpers

extension IO.Buffer.Aligned {
    /// Creates a deliberately misaligned view for testing alignment validation.
    ///
    /// This is package-internal for use in tests only. It creates a view
    /// that is offset from the aligned base, simulating a misaligned buffer.
    ///
    /// - Parameter offset: The number of bytes to offset (1 to alignment-1).
    /// - Parameter body: A closure receiving the misaligned buffer pointer.
    /// - Returns: The value returned by `body`.
    ///
    /// - Important: The misaligned pointer is only valid within `body`.
    package func withMisalignedView<T>(
        offset: Int,
        _ body: (UnsafeRawBufferPointer) throws -> T
    ) rethrows -> T {
        precondition(offset > 0 && offset < alignment, "Offset must break alignment")
        precondition(offset < count, "Offset exceeds buffer size")

        let misaligned = pointer.advanced(by: offset)
        let remaining = count - offset
        return try body(UnsafeRawBufferPointer(start: misaligned, count: remaining))
    }

    /// Creates a deliberately misaligned mutable view for testing.
    ///
    /// - Parameter offset: The number of bytes to offset.
    /// - Parameter body: A closure receiving the misaligned buffer pointer.
    /// - Returns: The value returned by `body`.
    package mutating func withMisalignedMutableView<T>(
        offset: Int,
        _ body: (UnsafeMutableRawBufferPointer) throws -> T
    ) rethrows -> T {
        precondition(offset > 0 && offset < alignment, "Offset must break alignment")
        precondition(offset < count, "Offset exceeds buffer size")

        let misaligned = pointer.advanced(by: offset)
        let remaining = count - offset
        return try body(UnsafeMutableRawBufferPointer(start: misaligned, count: remaining))
    }
}

// MARK: - Convenience

extension IO.Buffer.Aligned {
    /// Creates a page-aligned buffer.
    ///
    /// This is a convenience for allocating buffers aligned to the system
    /// page size, which is suitable for most Direct I/O operations.
    ///
    /// - Parameter byteCount: The number of bytes to allocate.
    /// - Throws: `Error` if allocation fails.
    public static func pageAligned(byteCount: Int) throws(Error) -> Self {
        try Self(byteCount: byteCount, alignment: IO.Memory.pageSize)
    }

    /// Creates a buffer aligned to the given Direct I/O requirements.
    ///
    /// - Parameters:
    ///   - byteCount: The number of bytes to allocate.
    ///   - requirements: The alignment requirements from `IO.File.Direct.Requirements`.
    /// - Throws: `Error` if allocation fails or requirements are unknown.
    public static func aligned(
        byteCount: Int,
        for requirements: IO.File.Direct.Requirements
    ) throws(Error) -> Self {
        guard case .known(let alignment) = requirements else {
            throw .allocationFailed
        }
        return try Self(byteCount: byteCount, alignment: alignment.bufferAlignment)
    }
}
