//
//  IO.File.Clone.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 30/12/2025.
//

/// Namespace for file cloning (copy-on-write reflink) operations.
///
/// File cloning creates a lightweight copy that shares storage with the original
/// until either file is modified. This is significantly faster than a byte-by-byte
/// copy for large files on supported filesystems.
///
/// ## Platform Support
///
/// | Platform | Filesystem | Mechanism |
/// |----------|------------|-----------|
/// | macOS | APFS | `clonefile()` |
/// | Linux | Btrfs, XFS | `ioctl(FICLONE)` |
/// | Linux | Any | `copy_file_range()` (may CoW) |
/// | Windows | ReFS | `FSCTL_DUPLICATE_EXTENTS_TO_FILE` |
///
/// ## Usage
///
/// ```swift
/// // Clone with fallback to copy
/// try IO.File.Clone.clone(
///     from: sourcePath,
///     to: destinationPath,
///     behavior: .reflinkOrCopy
/// )
///
/// // Probe capability first
/// let cap = try IO.File.Clone.capability(at: sourcePath)
/// if cap == .reflink {
///     try IO.File.Clone.clone(from: sourcePath, to: destinationPath, behavior: .reflinkOrFail)
/// }
/// ```
extension IO.File {
    public enum Clone {}
}
