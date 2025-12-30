//
//  IO.File.Direct.Capability.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 30/12/2025.
//

extension IO.File.Direct {
    /// The Direct I/O capability of a file handle or path.
    ///
    /// Capability indicates whether Direct I/O can be used, not whether
    /// it is currently enabled. Use this to probe support before opening
    /// a file with `.direct` mode.
    ///
    /// ## Platform Capabilities
    ///
    /// | Platform | `.direct` | `.uncached` |
    /// |----------|-----------|-------------|
    /// | Linux | Filesystem-dependent | No |
    /// | Windows | Filesystem-dependent | No |
    /// | macOS | No | Always |
    public enum Capability: Sendable, Equatable {
        /// Strict Direct I/O is supported.
        ///
        /// The file or volume supports `O_DIRECT` (Linux) or
        /// `FILE_FLAG_NO_BUFFERING` (Windows) with known alignment requirements.
        case directSupported(Requirements.Alignment)

        /// Only best-effort uncached mode is supported (macOS).
        ///
        /// `fcntl(F_NOCACHE)` can be used, but no strict alignment
        /// requirements apply.
        case uncachedOnly

        /// Neither Direct I/O nor uncached mode is supported.
        ///
        /// Only buffered I/O is available.
        case bufferedOnly
    }
}

// MARK: - Convenience

extension IO.File.Direct.Capability {
    /// Whether strict Direct I/O is available.
    public var supportsDirect: Bool {
        if case .directSupported = self { return true }
        return false
    }

    /// Whether any form of cache bypass is available.
    public var supportsBypass: Bool {
        switch self {
        case .directSupported, .uncachedOnly:
            return true
        case .bufferedOnly:
            return false
        }
    }

    /// The alignment requirements, if Direct I/O is supported.
    public var alignment: IO.File.Direct.Requirements.Alignment? {
        if case .directSupported(let alignment) = self {
            return alignment
        }
        return nil
    }
}
