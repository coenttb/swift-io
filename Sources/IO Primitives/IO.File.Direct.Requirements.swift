//
//  IO.File.Direct.Requirements.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 30/12/2025.
//

import SystemPackage

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
    ///     var buffer = try Buffer.Aligned(
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

// MARK: - Validation Accessors

extension IO.File.Direct.Requirements.Alignment {
    /// Accessor for buffer alignment validation.
    public struct Buffer: Sendable {
        let alignment: IO.File.Direct.Requirements.Alignment

        /// Validates that a buffer address is properly aligned.
        ///
        /// - Parameter address: The memory address to validate.
        /// - Returns: `true` if the address is aligned to `bufferAlignment`.
        public func isAligned(_ address: UnsafeRawPointer) -> Bool {
            Int(bitPattern: address) % alignment.bufferAlignment == 0
        }
    }

    /// Accessor for buffer alignment validation.
    public var buffer: Buffer { Buffer(alignment: self) }

    /// Accessor for offset alignment validation.
    public struct Offset: Sendable {
        let alignment: IO.File.Direct.Requirements.Alignment

        /// Validates that a file offset is properly aligned.
        ///
        /// - Parameter offset: The file offset to validate.
        /// - Returns: `true` if the offset is a multiple of `offsetAlignment`.
        public func isAligned(_ offset: Int64) -> Bool {
            Int(offset) % alignment.offsetAlignment == 0
        }
    }

    /// Accessor for offset alignment validation.
    public var offset: Offset { Offset(alignment: self) }

    /// Accessor for length validation.
    public struct Length: Sendable {
        let alignment: IO.File.Direct.Requirements.Alignment

        /// Validates that an I/O length is a valid multiple.
        ///
        /// - Parameter length: The transfer length to validate.
        /// - Returns: `true` if the length is a multiple of `lengthMultiple`.
        public func isValid(_ length: Int) -> Bool {
            length % alignment.lengthMultiple == 0
        }
    }

    /// Accessor for length validation.
    public var length: Length { Length(alignment: self) }

    /// Validates all alignment requirements for an I/O operation.
    ///
    /// - Parameters:
    ///   - bufferAddress: The buffer address.
    ///   - fileOffset: The file offset.
    ///   - transferLength: The transfer length.
    /// - Returns: The first validation failure, or `nil` if all pass.
    public func validate(
        buffer bufferAddress: UnsafeRawPointer,
        offset fileOffset: Int64,
        length transferLength: Int
    ) -> IO.File.Direct.Error? {
        if !buffer.isAligned(bufferAddress) {
            return .misalignedBuffer(
                address: Int(bitPattern: bufferAddress),
                required: bufferAlignment
            )
        }
        if !offset.isAligned(fileOffset) {
            return .misalignedOffset(
                offset: fileOffset,
                required: offsetAlignment
            )
        }
        if !length.isValid(transferLength) {
            return .invalidLength(
                length: transferLength,
                requiredMultiple: lengthMultiple
            )
        }
        return nil
    }
}

// MARK: - Platform-Specific Initialization

#if os(macOS)
extension IO.File.Direct.Requirements {
    /// Creates requirements for a path.
    ///
    /// On macOS, true Direct I/O is not supported. Only `.uncached` mode
    /// (F_NOCACHE hint) is available, which has no alignment requirements.
    public init(_ path: FilePath) {
        self = .unknown(reason: .platformUnsupported)
    }
}
#endif

#if os(Linux)
import Glibc
import CLinuxShim

extension IO.File.Direct.Requirements {
    /// Creates requirements for a path.
    ///
    /// On Linux, O_DIRECT alignment constraints are not reliably discoverable.
    /// Returns `.unknown` to fail closed. Callers should use
    /// `.auto(.fallbackToBuffered)` for best-effort operation.
    public init(_ path: FilePath) {
        // Linux O_DIRECT alignment is not reliably discoverable.
        // statfs.f_bsize is the optimal transfer size, NOT the alignment requirement.
        // Actual requirements depend on device sector size, filesystem, and driver.
        self = .unknown(reason: .sectorSizeUndetermined)
    }
}
#endif

#if os(Windows)
import WinSDK

extension IO.File.Direct.Requirements {
    /// Creates requirements for a path.
    ///
    /// Uses GetDiskFreeSpaceW to determine sector size.
    /// This is the minimal safe alignment for FILE_FLAG_NO_BUFFERING.
    public init(_ path: FilePath) {
        // Extract the root path (e.g., "C:\" from "C:\Users\...")
        guard let rootPath = Self.extractRootPath(from: path.string) else {
            self = .unknown(reason: .sectorSizeUndetermined)
            return
        }

        var sectorsPerCluster: DWORD = 0
        var bytesPerSector: DWORD = 0
        var numberOfFreeClusters: DWORD = 0
        var totalNumberOfClusters: DWORD = 0

        let result = rootPath.withCString(encodedAs: UTF16.self) { root in
            GetDiskFreeSpaceW(
                root,
                &sectorsPerCluster,
                &bytesPerSector,
                &numberOfFreeClusters,
                &totalNumberOfClusters
            )
        }

        guard result != 0, bytesPerSector > 0 else {
            self = .unknown(reason: .sectorSizeUndetermined)
            return
        }

        self = .known(Alignment(uniform: Int(bytesPerSector)))
    }

    /// Extracts the root path from a file path.
    private static func extractRootPath(from path: String) -> String? {
        // Handle UNC paths
        if path.hasPrefix("\\\\") {
            let components = path.dropFirst(2).split(separator: "\\", maxSplits: 2)
            if components.count >= 2 {
                return "\\\\" + components[0] + "\\" + components[1] + "\\"
            }
            return nil
        }

        // Handle extended-length paths
        if path.hasPrefix("\\\\?\\") {
            let rest = path.dropFirst(4)
            if rest.count >= 2 && rest.dropFirst().hasPrefix(":") {
                return String(path.prefix(7))
            }
            return nil
        }

        // Handle standard drive paths
        if path.count >= 2 && path.dropFirst().hasPrefix(":") {
            return String(path.prefix(3))
        }

        return nil
    }
}
#endif
