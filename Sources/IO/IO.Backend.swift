//
//  IO.Backend.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 07/01/2026.
//

extension IO {
    /// Platform I/O backend detection.
    ///
    /// Provides information about which I/O strategies are available
    /// on the current platform.
    ///
    /// ## Backend Hierarchy
    ///
    /// 1. **Completion-based** (io_uring/IOCP): Highest performance, available on Linux 5.1+ and Windows
    /// 2. **Event-driven** (kqueue/epoll): Available on all Unix-like platforms
    /// 3. **Blocking**: Always available, uses dedicated OS threads
    ///
    /// ## Usage
    /// ```swift
    /// switch IO.Backend.best {
    /// case .completionBased:
    ///     // Use IO.Completion.Queue for proactor-style I/O
    /// case .eventDriven:
    ///     // Use IO.Event.Selector for reactor-style I/O
    /// case .blocking:
    ///     // Use IO.Blocking.Lane for thread-pool I/O
    /// }
    /// ```
    ///
    /// ## Simplified Usage
    /// For most use cases, use `IO.run { }` which automatically uses
    /// the blocking lane (simplest and most portable).
    public enum Backend: Sendable, Equatable {
        /// Blocking thread pool (IO.Blocking.Lane).
        ///
        /// Always available. Uses dedicated OS threads for blocking operations.
        case blocking

        /// Event-driven readiness notification (IO.Event.Selector).
        ///
        /// Uses kqueue on Darwin, epoll on Linux.
        /// Reactor pattern: notifies when I/O is ready.
        case eventDriven

        /// Completion-based asynchronous I/O (IO.Completion.Queue).
        ///
        /// Uses io_uring on Linux 5.1+, IOCP on Windows.
        /// Proactor pattern: notifies when I/O is complete.
        case completionBased

        /// The best available backend for this platform.
        ///
        /// Selection priority:
        /// 1. Completion-based (Linux with io_uring, Windows with IOCP)
        /// 2. Blocking (Darwin and older Linux)
        ///
        /// Note: Event-driven is available but not auto-selected because
        /// the blocking lane is simpler for most use cases and completions
        /// are preferred when available.
        ///
        /// ## Platform Behavior
        /// - **Linux 5.1+**: `.completionBased` (io_uring)
        /// - **Linux <5.1**: `.blocking`
        /// - **Windows**: `.completionBased` (IOCP)
        /// - **Darwin**: `.blocking`
        public static var best: Backend {
            #if os(Linux)
                if IO.Completion.Queue.isAvailable {
                    return .completionBased
                }
                return .blocking
            #elseif os(Windows)
                return .completionBased
            #else
                return .blocking
            #endif
        }

        /// Whether completion-based I/O is available.
        ///
        /// Returns `true` on:
        /// - Linux with io_uring support (kernel 5.1+)
        /// - Windows (IOCP always available)
        public static var hasCompletions: Bool {
            IO.Completion.Queue.isAvailable
        }

        /// Whether event-driven I/O is available.
        ///
        /// Returns `true` on all Unix-like platforms (kqueue/epoll).
        public static var hasEvents: Bool {
            #if os(Windows)
                return false
            #else
                return true
            #endif
        }

        /// Whether blocking I/O is available.
        ///
        /// Always returns `true` - blocking is universally supported.
        public static var hasBlocking: Bool {
            true
        }
    }
}
