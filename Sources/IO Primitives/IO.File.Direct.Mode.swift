//
//  IO.File.Direct.Mode.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 30/12/2025.
//

extension IO.File.Direct {
    /// The cache mode for file I/O operations.
    ///
    /// This mode is set at handle open time and applies to all operations
    /// on that handle. Mixing modes on a single handle is not supported.
    ///
    /// ## Platform Behavior
    ///
    /// | Mode | Linux | Windows | macOS |
    /// |------|-------|---------|-------|
    /// | `.direct` | `O_DIRECT` | `NO_BUFFERING` | Error (use `.uncached`) |
    /// | `.uncached` | (not available) | (not available) | `F_NOCACHE` |
    /// | `.buffered` | Normal | Normal | Normal |
    /// | `.auto(...)` | See policy | See policy | → `.uncached` |
    public enum Mode: Sendable, Equatable {
        /// Strict Direct I/O with alignment requirements.
        ///
        /// Bypasses the page cache entirely. Requires aligned buffers, offsets,
        /// and I/O lengths. Available on Linux (`O_DIRECT`) and Windows
        /// (`FILE_FLAG_NO_BUFFERING`).
        ///
        /// - Important: Not available on macOS. Use `.uncached` instead.
        /// - Precondition: `requirements()` must return `.known(...)`.
        case direct

        /// Best-effort cache bypass (macOS only).
        ///
        /// Requests that the kernel avoid caching data, but this is a hint,
        /// not a guarantee. No alignment requirements are imposed.
        ///
        /// On macOS, uses `fcntl(F_NOCACHE, 1)` which can be applied after open.
        ///
        /// - Note: This mode is only meaningful on macOS. On Linux/Windows,
        ///   either use `.direct` for true bypass or `.buffered`.
        case uncached

        /// Normal buffered I/O through the page cache.
        ///
        /// This is the default and most compatible mode. The operating system
        /// caches data in memory for faster subsequent access.
        case buffered

        /// Automatic mode selection based on policy.
        ///
        /// The system chooses the most appropriate mode based on platform
        /// capabilities and the specified policy.
        case auto(policy: Policy)

        /// Policy for automatic mode selection.
        public enum Policy: Sendable, Equatable {
            /// Fall back to buffered I/O if direct is unavailable or alignment fails.
            ///
            /// Behavior by platform:
            /// - **macOS**: Uses `.uncached` (matches intent: avoid cache pollution)
            /// - **Linux/Windows**: Uses `.direct` if requirements known and alignment
            ///   satisfied, otherwise falls back to `.buffered`
            ///
            /// This is the practical choice for portable code.
            case fallbackToBuffered

            /// Error if direct I/O requirements cannot be satisfied.
            ///
            /// Behavior by platform:
            /// - **macOS**: Uses `.uncached` (never errors, since no alignment required)
            /// - **Linux/Windows**: Errors on alignment violation or unknown requirements
            ///
            /// Use when you need cache bypass and want explicit failure on misconfiguration.
            case errorOnViolation
        }
    }
}

// MARK: - Resolved Mode

extension IO.File.Direct.Mode {
    /// The resolved mode after platform-specific evaluation.
    ///
    /// This represents the actual mode that will be used, after `.auto`
    /// policies have been resolved for the current platform.
    public enum Resolved: Sendable, Equatable {
        /// Strict Direct I/O is active.
        case direct

        /// Best-effort uncached mode is active (macOS).
        case uncached

        /// Normal buffered I/O is active.
        case buffered
    }
}

// MARK: - Resolution

extension IO.File.Direct.Mode {
    /// Resolves the requested mode to a concrete mode based on platform and requirements.
    ///
    /// This is the single point of truth for `.auto` policy resolution.
    /// All mode decisions flow through this function.
    ///
    /// ## Resolution Rules
    ///
    /// | Requested | Platform | Requirements | Result |
    /// |-----------|----------|--------------|--------|
    /// | `.direct` | macOS | any | throws `.notSupported` |
    /// | `.direct` | Linux/Windows | `.unknown` | throws `.notSupported` |
    /// | `.direct` | Linux/Windows | `.known` | `.direct` |
    /// | `.uncached` | macOS | any | `.uncached` |
    /// | `.uncached` | Linux/Windows | any | throws `.notSupported` |
    /// | `.buffered` | any | any | `.buffered` |
    /// | `.auto(.fallbackToBuffered)` | macOS | any | `.uncached` |
    /// | `.auto(.fallbackToBuffered)` | Linux/Windows | `.known` | `.direct` |
    /// | `.auto(.fallbackToBuffered)` | Linux/Windows | `.unknown` | `.buffered` |
    /// | `.auto(.errorOnViolation)` | macOS | any | `.uncached` |
    /// | `.auto(.errorOnViolation)` | Linux/Windows | `.known` | `.direct` |
    /// | `.auto(.errorOnViolation)` | Linux/Windows | `.unknown` | throws `.notSupported` |
    ///
    /// - Parameter requirements: The alignment requirements for the file/path.
    /// - Returns: The resolved mode to use.
    /// - Throws: `IO.File.Direct.Error.notSupported` if the requested mode cannot be satisfied.
    public func resolve(
        given requirements: IO.File.Direct.Requirements
    ) throws(IO.File.Direct.Error) -> Resolved {
        #if os(macOS)
        return try resolveMacOS()
        #else
        return try resolveLinuxWindows(requirements: requirements)
        #endif
    }

    #if os(macOS)
    /// macOS resolution: .uncached is the only cache bypass available.
    private func resolveMacOS() throws(IO.File.Direct.Error) -> Resolved {
        switch self {
        case .direct:
            // Strict Direct I/O not available on macOS
            throw .notSupported

        case .uncached:
            return .uncached

        case .buffered:
            return .buffered

        case .auto:
            // On macOS, .auto always resolves to .uncached
            // (matches intent: avoid cache pollution)
            return .uncached
        }
    }
    #endif

    #if !os(macOS)
    /// Linux/Windows resolution: .direct requires known requirements.
    private func resolveLinuxWindows(
        requirements: IO.File.Direct.Requirements
    ) throws(IO.File.Direct.Error) -> Resolved {
        switch self {
        case .direct:
            // .direct requires known requirements
            guard case .known = requirements else {
                throw .notSupported
            }
            return .direct

        case .uncached:
            // .uncached (F_NOCACHE) is macOS-only
            throw .notSupported

        case .buffered:
            return .buffered

        case .auto(let policy):
            return try resolveAutoLinuxWindows(policy: policy, requirements: requirements)
        }
    }

    /// Resolves .auto policy on Linux/Windows.
    private func resolveAutoLinuxWindows(
        policy: Policy,
        requirements: IO.File.Direct.Requirements
    ) throws(IO.File.Direct.Error) -> Resolved {
        switch requirements {
        case .known:
            // Requirements known: use .direct
            return .direct

        case .unknown:
            // Requirements unknown: policy determines behavior
            switch policy {
            case .fallbackToBuffered:
                return .buffered
            case .errorOnViolation:
                throw .notSupported
            }
        }
    }
    #endif
}
