//
//  IO.File+open.swift
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

// MARK: - Open Function

extension IO.File {
    /// Opens a file and returns a handle.
    ///
    /// This is the integration point for Phase 3 Direct I/O. All mode
    /// resolution happens here:
    ///
    /// 1. Requirements are discovered (Linux/Windows) or marked as unknown (macOS)
    /// 2. The requested cache mode is resolved via `Mode.resolve(given:)`
    /// 3. Platform-specific flags are computed
    /// 4. The file is opened with appropriate flags
    /// 5. macOS: `F_NOCACHE` is applied post-open if resolved to `.uncached`
    ///
    /// - Parameters:
    ///   - path: The file path.
    ///   - options: Open options (access mode, create, truncate, cache mode).
    /// - Returns: A file handle with Direct I/O state.
    /// - Throws: `IO.File.Open.Error` on failure.
    public static func open(
        _ path: String,
        options: Open.Options = .init()
    ) throws(Open.Error) -> Handle {
        // 1. Discover requirements
        let requirements: IO.File.Direct.Requirements
        #if os(macOS)
        // macOS doesn't have strict Direct I/O; F_NOCACHE has no alignment requirements
        requirements = .unknown(reason: .platformUnsupported)
        #else
        do {
            requirements = try IO.File.Direct.getRequirements(at: path)
        } catch {
            requirements = .unknown(reason: .sectorSizeUndetermined)
        }
        #endif

        // 2. Resolve requested mode
        let resolved: IO.File.Direct.Mode.Resolved
        do {
            resolved = try options.cache.resolve(given: requirements)
        } catch {
            throw Open.Error.directNotSupported
        }

        // 3. Open with platform-specific flags
        let descriptor: IO.File.Descriptor
        #if os(Windows)
        let (desiredAccess, creationDisposition, flagsAndAttributes) = Syscalls.openFlags(
            access: options.access,
            create: options.create,
            truncate: options.truncate,
            direct: resolved == .direct
        )
        descriptor = try Syscalls.open(
            path: path,
            desiredAccess: desiredAccess,
            creationDisposition: creationDisposition,
            flagsAndAttributes: flagsAndAttributes
        )
        #else
        let flags = Syscalls.openFlags(
            access: options.access,
            create: options.create,
            truncate: options.truncate,
            direct: resolved == .direct
        )
        descriptor = try Syscalls.open(path: path, flags: flags)
        #endif

        // 4. macOS: apply F_NOCACHE post-open
        #if os(macOS)
        if resolved == .uncached {
            do {
                try IO.File.Direct.setNoCache(descriptor: descriptor, enabled: true)
            } catch {
                // Close descriptor and rethrow
                Syscalls.close(descriptor)
                throw Open.Error.platform(code: -1, message: "Failed to set F_NOCACHE")
            }
        }
        #endif

        return Handle(
            descriptor: descriptor,
            direct: resolved,
            requirements: requirements
        )
    }
}
