//
//  IO.File.Direct.Requirements.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 30/12/2025.
//

extension IO.File.Direct {
    /// Alignment requirements for Direct I/O operations.
    ///
    /// Direct I/O on Linux and Windows requires strict alignment of:
    /// - Buffer memory address
    /// - File offset
    /// - I/O transfer length
    ///
    /// Requirements are discovered at runtime because they depend on:
    /// - The underlying storage device's sector size
    /// - Filesystem constraints
    /// - Volume configuration
    ///
    /// ## Known vs Unknown
    ///
    /// Requirements are modeled as either `.known` (we have concrete values)
    /// or `.unknown` (we cannot determine requirements reliably).
    ///
    /// **Critical invariant:** `.direct` mode requires `.known` requirements.
    /// If requirements are `.unknown`, Direct I/O is `.notSupported`.
    ///
    /// ## Example
    ///
    /// ```swift
    /// let req = try handle.direct.requirements()
    /// switch req {
    /// case .known(let alignment):
    ///     // Safe to use .direct mode
    ///     var buffer = try IO.Buffer.Aligned(
    ///         byteCount: 4096,
    ///         alignment: alignment.bufferAlignment
    ///     )
    ///     try handle.read(into: &buffer, at: 0)
    ///
    /// case .unknown(let reason):
    ///     // Cannot use .direct mode safely
    ///     // Fall back to .buffered or use .auto(policy: .fallbackToBuffered)
    /// }
    /// ```
    public enum Requirements: Sendable, Equatable {
        /// Alignment requirements are known and can be satisfied.
        case known(Alignment)

        /// Alignment requirements could not be determined.
        ///
        /// Direct I/O is not supported when requirements are unknown.
        /// Use `.buffered` mode or `.auto(policy: .fallbackToBuffered)`.
        case unknown(reason: Reason)

        /// Concrete alignment values for Direct I/O.
        public struct Alignment: Sendable, Equatable {
            /// Required alignment for buffer memory addresses.
            ///
            /// The buffer pointer passed to read/write must have an address
            /// that is a multiple of this value.
            ///
            /// Typical values: 512 (legacy), 4096 (modern SSDs/NVMe).
            public let bufferAlignment: Int

            /// Required alignment for file offsets.
            ///
            /// The file position for read/write operations must be a multiple
            /// of this value.
            ///
            /// Usually matches `bufferAlignment` but may differ on some systems.
            public let offsetAlignment: Int

            /// Required multiple for I/O transfer lengths.
            ///
            /// The number of bytes read/written must be a multiple of this value.
            /// Partial sector I/O is not allowed in Direct mode.
            ///
            /// Usually matches `bufferAlignment`.
            public let lengthMultiple: Int

            public init(
                bufferAlignment: Int,
                offsetAlignment: Int,
                lengthMultiple: Int
            ) {
                self.bufferAlignment = bufferAlignment
                self.offsetAlignment = offsetAlignment
                self.lengthMultiple = lengthMultiple
            }

            /// Creates alignment with a single value for all requirements.
            ///
            /// Use when buffer, offset, and length all share the same alignment.
            public init(uniform alignment: Int) {
                self.bufferAlignment = alignment
                self.offsetAlignment = alignment
                self.lengthMultiple = alignment
            }
        }

        /// Reason why requirements could not be determined.
        public enum Reason: Sendable, Equatable, CustomStringConvertible {
            /// The platform does not support strict Direct I/O.
            ///
            /// macOS only supports `.uncached` mode (best-effort hint).
            case platformUnsupported

            /// The storage device's sector size could not be determined.
            ///
            /// On Windows, this occurs when `GetDiskFreeSpaceW` fails
            /// (e.g., network filesystems, unusual volume configurations).
            case sectorSizeUndetermined

            /// The filesystem does not support Direct I/O.
            ///
            /// Some filesystems (e.g., certain network filesystems, FUSE)
            /// may not support `O_DIRECT` or `NO_BUFFERING`.
            case filesystemUnsupported

            /// The file handle is not suitable for Direct I/O.
            case invalidHandle

            public var description: String {
                switch self {
                case .platformUnsupported:
                    return "Platform does not support strict Direct I/O"
                case .sectorSizeUndetermined:
                    return "Could not determine sector size"
                case .filesystemUnsupported:
                    return "Filesystem does not support Direct I/O"
                case .invalidHandle:
                    return "Invalid file handle"
                }
            }
        }
    }
}

// MARK: - Validation

extension IO.File.Direct.Requirements.Alignment {
    /// Validates that a buffer address is properly aligned.
    ///
    /// - Parameter address: The memory address to validate.
    /// - Returns: `true` if the address is aligned to `bufferAlignment`.
    public func isBufferAligned(_ address: UnsafeRawPointer) -> Bool {
        Int(bitPattern: address) % bufferAlignment == 0
    }

    /// Validates that a file offset is properly aligned.
    ///
    /// - Parameter offset: The file offset to validate.
    /// - Returns: `true` if the offset is a multiple of `offsetAlignment`.
    public func isOffsetAligned(_ offset: Int64) -> Bool {
        Int(offset) % offsetAlignment == 0
    }

    /// Validates that an I/O length is a valid multiple.
    ///
    /// - Parameter length: The transfer length to validate.
    /// - Returns: `true` if the length is a multiple of `lengthMultiple`.
    public func isLengthValid(_ length: Int) -> Bool {
        length % lengthMultiple == 0
    }

    /// Validates all alignment requirements for an I/O operation.
    ///
    /// - Parameters:
    ///   - buffer: The buffer address.
    ///   - offset: The file offset.
    ///   - length: The transfer length.
    /// - Returns: The first validation failure, or `nil` if all pass.
    public func validate(
        buffer: UnsafeRawPointer,
        offset: Int64,
        length: Int
    ) -> IO.File.Direct.Error? {
        if !isBufferAligned(buffer) {
            return .misalignedBuffer(
                address: Int(bitPattern: buffer),
                required: bufferAlignment
            )
        }
        if !isOffsetAligned(offset) {
            return .misalignedOffset(
                offset: offset,
                required: offsetAlignment
            )
        }
        if !isLengthValid(length) {
            return .invalidLength(
                length: length,
                requiredMultiple: lengthMultiple
            )
        }
        return nil
    }
}
