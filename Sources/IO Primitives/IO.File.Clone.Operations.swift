//
//  IO.File.Clone.Operations.swift
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

// MARK: - Public API

extension IO.File.Clone {
    /// Clones a file from source to destination.
    ///
    /// This is the primary entry point for file cloning. The behavior parameter
    /// controls whether to require reflink, allow fallback to copy, or skip
    /// reflink entirely.
    ///
    /// - Parameters:
    ///   - source: Path to the source file.
    ///   - destination: Path to the destination (must not exist).
    ///   - behavior: The cloning behavior policy.
    /// - Returns: The result indicating whether reflink or copy was used.
    /// - Throws: `IO.File.Clone.Error` if the operation fails.
    ///
    /// ## Example
    ///
    /// ```swift
    /// // Best-effort clone with fallback
    /// let result = try IO.File.Clone.clone(
    ///     from: "/path/to/source",
    ///     to: "/path/to/destination",
    ///     behavior: .reflinkOrCopy
    /// )
    ///
    /// switch result {
    /// case .reflinked:
    ///     print("Used zero-copy clone")
    /// case .copied:
    ///     print("Fell back to byte copy")
    /// }
    /// ```
    public static func clone(
        from source: String,
        to destination: String,
        behavior: Behavior
    ) throws(Error) -> Result {
        switch behavior {
        case .reflinkOrFail:
            return try cloneReflinkOnly(from: source, to: destination)
        case .reflinkOrCopy:
            return try cloneWithFallback(from: source, to: destination)
        case .copyOnly:
            try copyOnly(from: source, to: destination)
            return .copied
        }
    }

    /// Probes the cloning capability for a given path.
    ///
    /// This is a cheap, local operation that checks the filesystem type.
    /// Use this to decide whether to attempt reflink or skip to copy.
    ///
    /// - Parameter path: The path to probe (typically the source file or its directory).
    /// - Returns: The capability of the filesystem at that path.
    /// - Throws: `IO.File.Clone.Error` if probing fails.
    ///
    /// ## Example
    ///
    /// ```swift
    /// let cap = try IO.File.Clone.capability(at: sourcePath)
    /// if cap == .reflink {
    ///     print("Filesystem supports zero-copy cloning")
    /// }
    /// ```
    public static func capability(at path: String) throws(Error) -> Capability {
        do {
            return try probeCapability(at: path)
        } catch {
            throw Error(from: error)
        }
    }
}

// MARK: - Internal Implementation

extension IO.File.Clone {
    /// Clones using reflink only; fails if unsupported.
    private static func cloneReflinkOnly(
        from source: String,
        to destination: String
    ) throws(Error) -> Result {
        #if os(macOS)
        let cloned: Bool
        do {
            cloned = try clonefileAttempt(source: source, destination: destination)
        } catch {
            throw Error(from: error)
        }

        if cloned {
            return .reflinked
        }
        throw Error.notSupported

        #elseif os(Linux)
        // On Linux, we need to open files to use FICLONE
        let srcFd = source.withCString { open($0, O_RDONLY) }
        guard srcFd >= 0 else {
            if errno == ENOENT {
                throw Error.sourceNotFound
            }
            throw Error.platform(code: errno, message: String(cString: strerror(errno)))
        }
        defer { close(srcFd) }

        // Create destination file
        let dstFd = destination.withCString { open($0, O_WRONLY | O_CREAT | O_EXCL, 0o644) }
        guard dstFd >= 0 else {
            if errno == EEXIST {
                throw Error.destinationExists
            }
            throw Error.platform(code: errno, message: String(cString: strerror(errno)))
        }
        defer { close(dstFd) }

        let cloned: Bool
        do {
            cloned = try ficloneAttempt(sourceFd: srcFd, destFd: dstFd)
        } catch {
            _ = destination.withCString { unlink($0) }
            throw Error(from: error)
        }

        if cloned {
            return .reflinked
        }
        // Clean up destination on failure
        _ = destination.withCString { unlink($0) }
        throw Error.notSupported

        #elseif os(Windows)
        // Windows reflink is very constrained; fail by default
        throw Error.notSupported

        #else
        throw Error.notSupported
        #endif
    }

    /// Clones using reflink if available, falls back to copy.
    private static func cloneWithFallback(
        from source: String,
        to destination: String
    ) throws(Error) -> Result {
        #if os(macOS)
        // macOS copyfile with COPYFILE_CLONE tries clone, falls back to copy
        // First try pure clonefile
        let cloned: Bool
        do {
            cloned = try clonefileAttempt(source: source, destination: destination)
        } catch {
            // Clonefile failed - fall through to copyfile
            cloned = false
        }

        if cloned {
            return .reflinked
        }

        // Use copyfile with COPYFILE_CLONE flag
        do {
            try copyfileClone(source: source, destination: destination)
            // We can't easily tell if it cloned or copied, assume best-effort worked
            return .copied
        } catch {
            throw Error(from: error)
        }

        #elseif os(Linux)
        // Try FICLONE first
        let srcFd = source.withCString { open($0, O_RDONLY) }
        guard srcFd >= 0 else {
            if errno == ENOENT {
                throw Error.sourceNotFound
            }
            throw Error.platform(code: errno, message: String(cString: strerror(errno)))
        }
        defer { close(srcFd) }

        // Get file size for copy_file_range
        var statBuf = stat()
        guard fstat(srcFd, &statBuf) == 0 else {
            throw Error.platform(code: errno, message: String(cString: strerror(errno)))
        }
        let size = Int(statBuf.st_size)

        // Create destination file
        let dstFd = destination.withCString { open($0, O_WRONLY | O_CREAT | O_EXCL, 0o644) }
        guard dstFd >= 0 else {
            if errno == EEXIST {
                throw Error.destinationExists
            }
            throw Error.platform(code: errno, message: String(cString: strerror(errno)))
        }
        defer { close(dstFd) }

        // Try FICLONE
        var reflinked = false
        do {
            reflinked = try ficloneAttempt(sourceFd: srcFd, destFd: dstFd)
        } catch {
            // FICLONE failed, fall through to copy_file_range
            reflinked = false
        }

        if reflinked {
            return .reflinked
        }

        // Use copy_file_range (may still use server-side copy)
        do {
            try copyFileRange(sourceFd: srcFd, destFd: dstFd, length: size)
            return .copied
        } catch {
            _ = destination.withCString { unlink($0) }
            throw Error(from: error)
        }

        #elseif os(Windows)
        do {
            try copyFile(source: source, destination: destination)
            return .copied
        } catch {
            throw Error(from: error)
        }

        #else
        throw Error.notSupported
        #endif
    }

    /// Copies a file without attempting reflink.
    private static func copyOnly(
        from source: String,
        to destination: String
    ) throws(Error) {
        #if os(macOS)
        do {
            try copyfileData(source: source, destination: destination)
        } catch {
            throw Error(from: error)
        }

        #elseif os(Linux)
        let srcFd = source.withCString { open($0, O_RDONLY) }
        guard srcFd >= 0 else {
            if errno == ENOENT {
                throw Error.sourceNotFound
            }
            throw Error.platform(code: errno, message: String(cString: strerror(errno)))
        }
        defer { close(srcFd) }

        var statBuf = Glibc.stat()
        guard fstat(srcFd, &statBuf) == 0 else {
            throw Error.platform(code: errno, message: String(cString: strerror(errno)))
        }
        let size = Int(statBuf.st_size)

        let dstFd = destination.withCString { open($0, O_WRONLY | O_CREAT | O_EXCL, 0o644) }
        guard dstFd >= 0 else {
            if errno == EEXIST {
                throw Error.destinationExists
            }
            throw Error.platform(code: errno, message: String(cString: strerror(errno)))
        }
        defer { close(dstFd) }

        do {
            try copyFileRange(sourceFd: srcFd, destFd: dstFd, length: size)
        } catch {
            _ = destination.withCString { unlink($0) }
            throw Error(from: error)
        }

        #elseif os(Windows)
        do {
            try copyFile(source: source, destination: destination)
        } catch {
            throw Error(from: error)
        }

        #else
        throw Error.notSupported
        #endif
    }
}
