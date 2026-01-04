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
    /// - Throws: `Kernel.File.Open.Error` on failure.
    public static func open(
        _ path: FilePath,
        options: Open.Options = .init()
    ) throws(Kernel.File.Open.Error) -> Kernel.File.Handle {
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
        // TODO: Add .cacheDisabled when kernel makes it public
        // if resolved == .uncached { kernelOptions.insert(.cacheDisabled) }

        // 4. Open via Kernel (kernel handles platform specifics internally)
        let descriptor = try Kernel.File.Open.open(
            path: path,
            mode: options.mode,
            options: kernelOptions,
            permissions: 0o644
        )

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
    ) throws(Kernel.File.Open.Error) -> Kernel.File.Handle {
        try open(FilePath(path), options: options)
    }
}
