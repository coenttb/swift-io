//
//  IO.Completion.Queue.shared.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 07/01/2026.
//

extension IO.Completion.Queue {
    /// The shared completion queue for proactor-style I/O.
    ///
    /// Lazily initialized on first access. Uses:
    /// - Best available driver (io_uring on Linux, IOCP on Windows)
    ///
    /// ## Platform Availability
    /// - **Linux**: Uses io_uring if kernel supports it
    /// - **Windows**: Uses IOCP
    /// - **Darwin**: Not available (use `IO.Event.Selector` instead)
    ///
    /// On unsupported platforms, calling this function throws `.failure(.capability(.backendUnavailable))`.
    /// Check `IO.Completion.Queue.isAvailable` before using.
    ///
    /// ## Usage
    /// ```swift
    /// if IO.Completion.Queue.isAvailable {
    ///     let queue = try await IO.Completion.Queue.shared()
    ///     let result = try await queue.submit(.read(from: fd, into: buffer, id: queue.id.next()))
    /// }
    /// ```
    ///
    /// ## Lifecycle
    /// - **Process-scoped singleton**: Lives for the entire process lifetime.
    /// - **No shutdown required**: Poll thread cleans up on process exit.
    /// - **Lazy start**: Poll thread spawns on first access.
    ///
    /// ## Global State (PATTERN REQUIREMENTS §6.6)
    /// This is an intentional process-global singleton. Rationale:
    /// - Completion queues are expensive resources (io_uring ring + poll thread)
    /// - Sharing the queue across completion-based operations reduces resource waste
    /// - Default configuration suits most use cases
    /// - Testable: Create a separate queue via `IO.Completion.Queue()` for isolated tests
    ///
    /// For advanced use cases (custom driver, explicit lifecycle),
    /// create your own queue with `IO.Completion.Queue(driver:)`.
    ///
    /// - Returns: The shared completion queue instance.
    /// - Throws: `IO.Completion.Failure` if initialization fails or platform doesn't support completions.
    public static func shared() async throws(IO.Completion.Failure) -> IO.Completion.Queue {
        try await _sharedQueue.value
    }

    /// Whether completion-based I/O is available on this platform.
    ///
    /// Returns `true` on:
    /// - Linux with io_uring support (kernel 5.1+)
    /// - Windows (IOCP always available)
    ///
    /// Returns `false` on:
    /// - Darwin (macOS, iOS, etc.)
    /// - Linux without io_uring support
    ///
    /// ## Usage
    /// ```swift
    /// if IO.Completion.Queue.isAvailable {
    ///     // Use completion-based I/O
    /// } else {
    ///     // Fall back to blocking or event-driven I/O
    /// }
    /// ```
    public static var isAvailable: Bool {
        #if os(Windows)
            return true
        #elseif os(Linux)
            return IO.Completion.IOUring.isSupported
        #else
            return false
        #endif
    }
}

/// Lazy singleton holder for the shared completion queue.
///
/// Uses an actor to ensure thread-safe lazy initialization of the queue.
/// The queue is created on first access and cached for process lifetime.
private actor SharedQueue {
    private var queue: IO.Completion.Queue?

    var value: IO.Completion.Queue {
        get async throws(IO.Completion.Failure) {
            if let existing = queue {
                return existing
            }
            let new = try await IO.Completion.Queue()
            queue = new
            return new
        }
    }
}

private let _sharedQueue = SharedQueue()
