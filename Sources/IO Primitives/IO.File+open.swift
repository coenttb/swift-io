//
//  IO.File+open.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 30/12/2025.
//

public import Kernel
public import SystemPackage

// MARK: - Open Function

extension IO.File {
    /// Opens a file and returns a handle.
    ///
    /// - Parameters:
    ///   - path: The file path.
    ///   - options: Open options (mode, create, truncate, cache mode).
    /// - Returns: A file handle with Direct I/O state.
    /// - Throws: `Kernel.Open.Error` on failure.
    public static func open(
        _ path: FilePath,
        options: Open.Options = .init()
    ) throws(Kernel.Open.Error) -> Kernel.File.Handle {
        // 1. Discover requirements
        let requirements = Kernel.File.Direct.Requirements(path)

        // 2. Resolve cache mode
        let resolved: Kernel.File.Direct.Mode.Resolved
        do {
            resolved = try options.cache.resolve(given: requirements)
        } catch {
            // Fall back to buffered if direct not supported
            resolved = .buffered
        }

        // 3. Build Kernel options
        var kernelOptions: Kernel.File.Open.Options = []
        if options.create { kernelOptions.insert(.create) }
        if options.truncate { kernelOptions.insert(.truncate) }
        if resolved == .direct { kernelOptions.insert(.direct) }

        // 4. Open via Kernel
        let descriptor = try Kernel.Open.open(
            path: path,
            mode: options.mode,
            options: kernelOptions,
            permissions: 0o644
        )

        // 5. macOS: apply F_NOCACHE post-open
        #if os(macOS)
            if resolved == .uncached {
                do {
                    try Kernel.File.Direct.setNoCache(descriptor: descriptor, enabled: true)
                } catch {
                    try? Kernel.Close.close(descriptor)
                    throw Kernel.Open.Error.io(.hardware)
                }
            }
        #endif

        return Kernel.File.Handle(
            descriptor: descriptor,
            direct: resolved,
            requirements: requirements
        )
    }

    /// Opens a file from a String path.
    ///
    /// Convenience overload that converts String to FilePath.
    @inlinable
    public static func open(
        _ path: String,
        options: Open.Options = .init()
    ) throws(Kernel.Open.Error) -> Kernel.File.Handle {
        try open(FilePath(path), options: options)
    }
}
