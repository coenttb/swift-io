//
//  IO.File.Direct.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 30/12/2025.
//

/// Namespace for Direct I/O operations (cache bypass).
///
/// Direct I/O bypasses the operating system's page cache, allowing data to flow
/// directly between user buffers and storage. This is useful for:
/// - Database engines that manage their own caching
/// - Large sequential I/O where cache pollution is undesirable
/// - Applications requiring predictable latency
///
/// ## Platform Semantics
///
/// | Platform | Flag | Semantics | Alignment Required |
/// |----------|------|-----------|-------------------|
/// | Linux | `O_DIRECT` | Strict bypass | Yes (buffer, offset, length) |
/// | Windows | `FILE_FLAG_NO_BUFFERING` | Strict bypass | Yes (sector-aligned) |
/// | macOS | `fcntl(F_NOCACHE)` | Best-effort hint | No |
///
/// **Important:** macOS `F_NOCACHE` is a *hint*, not a strict bypass. The kernel
/// may still cache data. Use `.uncached` mode on macOS, not `.direct`.
///
/// ## Handle-Level Constraint
///
/// Direct I/O mode is set at open time (Linux/Windows) or applied post-open (macOS).
/// Once set, all operations on the handle must comply with alignment requirements.
/// Mixing buffered and direct operations on the same handle is undefined behavior.
///
/// ## Alignment Requirements
///
/// On Linux and Windows, Direct I/O requires:
/// - **Buffer alignment**: Memory address must be aligned to sector/page boundary
/// - **Offset alignment**: File offset must be aligned
/// - **Length multiple**: I/O size must be a multiple of the alignment unit
///
/// Use `Buffer.Aligned` for portable aligned buffer allocation.
///
/// ## mmap Interaction
///
/// Mixing Direct I/O and memory-mapped I/O on the same file ranges is undefined
/// behavior. The page cache coherency model does not apply when Direct I/O bypasses
/// it. If you need both, use separate file handles and explicit synchronization.
///
/// ## Usage
///
/// ```swift
/// // Open with Direct I/O (Linux/Windows)
/// let handle = try IO.File.open(path, mode: .readWrite, cacheMode: .direct)
///
/// // Query requirements
/// let requirements = try handle.direct.requirements()
/// guard case .known(let align) = requirements else {
///     throw IO.File.Direct.Error.notSupported
/// }
///
/// // Allocate aligned buffer
/// var buffer = try Buffer.Aligned(
///     byteCount: 4096,
///     alignment: align.bufferAlignment
/// )
///
/// // Read with alignment validation
/// try handle.read(into: &buffer, at: 0)
/// ```
///
/// ```swift
/// // Portable code with auto-fallback
/// let handle = try IO.File.open(
///     path,
///     mode: .read,
///     cacheMode: .auto(policy: .fallbackToBuffered)
/// )
/// // On macOS: uses .uncached
/// // On Linux/Windows: uses .direct if alignment satisfied, else .buffered
/// ```
extension IO.File {
    public enum Direct {}
}

// MARK: - Public Requirements API

extension IO.File.Direct {
    /// Queries alignment requirements for a file path.
    ///
    /// Use this to determine whether Direct I/O is available and what
    /// alignment constraints apply before opening a file.
    ///
    /// ## Platform Behavior
    ///
    /// - **macOS**: Always returns `.unknown(.platformUnsupported)` because
    ///   `F_NOCACHE` has no alignment requirements.
    /// - **Linux**: Returns `.unknown(.sectorSizeUndetermined)` because
    ///   alignment constraints are not reliably discoverable. See notes below.
    /// - **Windows**: Returns `.known(...)` based on sector size from
    ///   `GetDiskFreeSpaceW`, or `.unknown` for network paths.
    ///
    /// ## Linux Alignment Discovery Limitations
    ///
    /// Linux `O_DIRECT` alignment requirements are not reliably derivable from
    /// standard APIs. They vary by filesystem, device, and configuration, and
    /// are often only enforced at syscall time via `EINVAL`.
    ///
    /// For production use on Linux, either:
    /// 1. Use `.auto(.fallbackToBuffered)` for best-effort operation
    /// 2. Provide explicit alignment via `Requirements(uniformAlignment:)`
    /// 3. Handle `EINVAL` errors as potential alignment violations
    ///
    /// Common safe alignments for reference:
    /// - 512 bytes: Legacy HDDs
    /// - 4096 bytes: Modern SSDs, NVMe, most ext4/XFS
    /// - Page size: Conservative fallback (typically 4096)
    ///
    /// - Parameter path: The file path to query.
    /// - Returns: The alignment requirements, or `.unknown` with a reason.
    public static func requirements(
        for path: String
    ) -> Requirements {
        #if os(macOS)
        return .unknown(reason: .platformUnsupported)
        #elseif os(Linux)
        // Fail closed - alignment not reliably discoverable
        return .unknown(reason: .sectorSizeUndetermined)
        #elseif os(Windows)
        do {
            return try getRequirements(at: path)
        } catch {
            return .unknown(reason: .sectorSizeUndetermined)
        }
        #else
        return .unknown(reason: .platformUnsupported)
        #endif
    }
}

// MARK: - Requirements Constructors

extension IO.File.Direct.Requirements {
    /// Creates known alignment requirements with explicit values.
    ///
    /// Use this when you know the specific alignment requirements for your
    /// storage configuration. This bypasses automatic discovery and allows
    /// Direct I/O on platforms where discovery fails.
    ///
    /// - Parameters:
    ///   - bufferAlignment: Required alignment for buffer addresses.
    ///   - offsetAlignment: Required alignment for file offsets.
    ///   - lengthMultiple: Required multiple for I/O lengths.
    public init(
        bufferAlignment: Int,
        offsetAlignment: Int,
        lengthMultiple: Int
    ) {
        self = .known(Alignment(
            bufferAlignment: bufferAlignment,
            offsetAlignment: offsetAlignment,
            lengthMultiple: lengthMultiple
        ))
    }

    /// Creates known alignment requirements with a uniform value.
    ///
    /// Convenience for when buffer, offset, and length all use the same alignment.
    ///
    /// - Parameter alignment: The uniform alignment value.
    public init(uniformAlignment alignment: Int) {
        self = .known(Alignment(uniform: alignment))
    }
}
