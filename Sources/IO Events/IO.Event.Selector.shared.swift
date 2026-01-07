//
//  IO.Event.Selector.shared.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 07/01/2026.
//

public import Kernel

extension IO.Event.Selector {
    /// The shared default selector for event-driven I/O.
    ///
    /// Lazily initialized on first access. Uses:
    /// - Platform-default driver (kqueue on Darwin, epoll on Linux)
    /// - Dedicated executor pool (process-global)
    ///
    /// ## Usage
    /// ```swift
    /// let selector = try await IO.Event.Selector.shared()
    /// let (id, token) = try await selector.register(fd, interest: .read)
    /// ```
    ///
    /// ## Lifecycle
    /// - **Process-scoped singleton**: Lives for the entire process lifetime.
    /// - **No shutdown required**: Poll thread cleans up on process exit.
    /// - **Lazy start**: Poll thread spawns on first access.
    ///
    /// ## Global State (PATTERN REQUIREMENTS §6.6)
    /// This is an intentional process-global singleton. Rationale:
    /// - Event selectors are expensive resources (poll thread + driver handle)
    /// - Sharing the selector across event-driven operations reduces resource waste
    /// - Default configuration suits most use cases
    /// - Testable: Create a separate selector via `.make(executor:)` for isolated tests
    ///
    /// For advanced use cases (custom executor, explicit lifecycle),
    /// create your own selector with `IO.Event.Selector.make(executor:)`.
    ///
    /// - Returns: The shared selector instance.
    /// - Throws: `Make.Error` if initialization fails on first access.
    public static func shared() async throws(Make.Error) -> IO.Event.Selector {
        try await _sharedSelector.value
    }
}

/// Lazy singleton holder for the shared selector.
///
/// Uses an actor to ensure thread-safe lazy initialization of the selector.
/// The selector is created on first access and cached for process lifetime.
private actor SharedSelector {
    private var selector: IO.Event.Selector?

    /// Process-global executor pool for the shared selector.
    private let executors = Kernel.Thread.Executors()

    var value: IO.Event.Selector {
        get async throws(IO.Event.Selector.Make.Error) {
            if let existing = selector {
                return existing
            }
            let executor = executors.next()
            let new = try await IO.Event.Selector.make(executor: executor)
            selector = new
            return new
        }
    }
}

private let _sharedSelector = SharedSelector()
