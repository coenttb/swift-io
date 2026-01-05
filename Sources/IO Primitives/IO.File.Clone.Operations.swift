//
//  IO.File.Clone.Operations.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 30/12/2025.
//

public import Kernel
public import SystemPackage

// MARK: - Type Aliases

extension IO.File.Clone {
    /// Error type from Kernel.
    public typealias Error = Kernel.File.Clone.Error

    /// Behavior policy from Kernel.
    public typealias Behavior = Kernel.File.Clone.Behavior

    /// Capability type from Kernel.
    public typealias Capability = Kernel.File.Clone.Capability

    /// Result type from Kernel.
    public typealias Result = Kernel.File.Clone.Result
}

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
    public static func clone(
        from source: FilePath,
        to destination: FilePath,
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
    public static func capability(at path: FilePath) throws(Error) -> Capability {
        do {
            return try Kernel.File.Clone.Capability.probe(at: path)
        } catch {
            throw .notSupported
        }
    }
}

// MARK: - Internal Implementation

extension IO.File.Clone {
    /// Clones using reflink only; fails if unsupported.
    private static func cloneReflinkOnly(
        from source: FilePath,
        to destination: FilePath
    ) throws(Error) -> Result {
        #if os(macOS)
            let cloned: Bool
            do {
                cloned = try Kernel.File.Clone.Clonefile.attempt(
                    source: source,
                    destination: destination
                )
            } catch {
                throw .notSupported
            }

            if cloned {
                return .reflinked
            }
            throw Error.notSupported

        #elseif os(Linux)
            // On Linux, we need to open files to use FICLONE
            let srcDescriptor: Kernel.Descriptor
            do {
                srcDescriptor = try Kernel.File.Open.open(
                    path: source,
                    mode: .read,
                    options: [],
                    permissions: 0
                )
            } catch let error as Kernel.File.Open.Error {
                if case .path(.notFound) = error {
                    throw Error.sourceNotFound
                }
                throw Error.notSupported
            }
            defer { try? Kernel.Close.close(srcDescriptor) }

            // Create destination file
            let dstDescriptor: Kernel.Descriptor
            do {
                dstDescriptor = try Kernel.File.Open.open(
                    path: destination,
                    mode: .write,
                    options: [.create, .exclusive],
                    permissions: 0o644
                )
            } catch let error as Kernel.File.Open.Error {
                if case .path(.exists) = error {
                    throw Error.destinationExists
                }
                throw Error.notSupported
            }
            defer { try? Kernel.Close.close(dstDescriptor) }

            let cloned: Bool
            do {
                cloned = try Kernel.File.Clone.Ficlone.attempt(
                    source: srcDescriptor,
                    destination: dstDescriptor
                )
            } catch let error as Kernel.File.Clone.Error.Syscall {
                try? Kernel.Unlink.unlink(destination)
                throw Error(from: error)
            } catch {
                try? Kernel.Unlink.unlink(destination)
                throw .notSupported
            }

            if cloned {
                return .reflinked
            }
            try? Kernel.Unlink.unlink(destination)
            throw Error.notSupported

        #elseif os(Windows)
            throw Error.notSupported

        #else
            throw Error.notSupported
        #endif
    }

    /// Clones using reflink if available, falls back to copy.
    private static func cloneWithFallback(
        from source: FilePath,
        to destination: FilePath
    ) throws(Error) -> Result {
        #if os(macOS)
            // First try pure clonefile
            let cloned: Bool
            do {
                cloned = try Kernel.File.Clone.Clonefile.attempt(
                    source: source,
                    destination: destination
                )
            } catch {
                // Clonefile failed - fall through to copyfile
                cloned = false
            }

            if cloned {
                return .reflinked
            }

            // Use copyfile with COPYFILE_CLONE flag
            do {
                try Kernel.File.Clone.Copyfile.clone(
                    source: source,
                    destination: destination
                )
                return .copied
            } catch {
                throw .notSupported
            }

        #elseif os(Linux)
            // Try FICLONE first
            let srcDescriptor: Kernel.Descriptor
            do {
                srcDescriptor = try Kernel.File.Open.open(
                    path: source,
                    mode: .read,
                    options: [],
                    permissions: 0
                )
            } catch let error as Kernel.File.Open.Error {
                if case .path(.notFound) = error {
                    throw Error.sourceNotFound
                }
                throw Error.notSupported
            }
            defer { try? Kernel.Close.close(srcDescriptor) }

            // Get file size for copy_file_range
            let size: Int
            do {
                size = try Kernel.File.Clone.Metadata.size(at: source)
            } catch {
                throw Error.notSupported
            }

            // Create destination file
            let dstDescriptor: Kernel.Descriptor
            do {
                dstDescriptor = try Kernel.File.Open.open(
                    path: destination,
                    mode: .write,
                    options: [.create, .exclusive],
                    permissions: 0o644
                )
            } catch let error as Kernel.File.Open.Error {
                if case .path(.exists) = error {
                    throw Error.destinationExists
                }
                throw Error.notSupported
            }
            defer { try? Kernel.Close.close(dstDescriptor) }

            // Try FICLONE
            var reflinked = false
            do {
                reflinked = try Kernel.File.Clone.Ficlone.attempt(
                    source: srcDescriptor,
                    destination: dstDescriptor
                )
            } catch {
                reflinked = false
            }

            if reflinked {
                return .reflinked
            }

            // Use copy_file_range
            do {
                try Kernel.File.Clone.CopyRange.copy(
                    source: srcDescriptor,
                    destination: dstDescriptor,
                    length: size
                )
                return .copied
            } catch let error as Kernel.File.Clone.Error.Syscall {
                try? Kernel.Unlink.unlink(destination)
                throw Error(from: error)
            } catch {
                try? Kernel.Unlink.unlink(destination)
                throw .notSupported
            }

        #elseif os(Windows)
            do {
                try Kernel.File.Clone.Copy.file(
                    source: source,
                    destination: destination
                )
                return .copied
            } catch {
                throw .notSupported
            }

        #else
            throw Error.notSupported
        #endif
    }

    /// Copies a file without attempting reflink.
    private static func copyOnly(
        from source: FilePath,
        to destination: FilePath
    ) throws(Error) {
        #if os(macOS)
            do {
                try Kernel.File.Clone.Copyfile.data(
                    source: source,
                    destination: destination
                )
            } catch {
                throw .notSupported
            }

        #elseif os(Linux)
            let srcDescriptor: Kernel.Descriptor
            do {
                srcDescriptor = try Kernel.File.Open.open(
                    path: source,
                    mode: .read,
                    options: [],
                    permissions: 0
                )
            } catch let error as Kernel.File.Open.Error {
                if case .path(.notFound) = error {
                    throw Error.sourceNotFound
                }
                throw Error.notSupported
            }
            defer { try? Kernel.Close.close(srcDescriptor) }

            let size: Int
            do {
                size = try Kernel.File.Clone.Metadata.size(at: source)
            } catch {
                throw Error.notSupported
            }

            let dstDescriptor: Kernel.Descriptor
            do {
                dstDescriptor = try Kernel.File.Open.open(
                    path: destination,
                    mode: .write,
                    options: [.create, .exclusive],
                    permissions: 0o644
                )
            } catch let error as Kernel.File.Open.Error {
                if case .path(.exists) = error {
                    throw Error.destinationExists
                }
                throw Error.notSupported
            }
            defer { try? Kernel.Close.close(dstDescriptor) }

            do {
                try Kernel.File.Clone.CopyRange.copy(
                    source: srcDescriptor,
                    destination: dstDescriptor,
                    length: size
                )
            } catch {
                try? Kernel.Unlink.unlink(destination)
                throw .notSupported
            }

        #elseif os(Windows)
            do {
                try Kernel.File.Clone.Copy.file(
                    source: source,
                    destination: destination
                )
            } catch {
                throw .notSupported
            }

        #else
            throw Error.notSupported
        #endif
    }
}
