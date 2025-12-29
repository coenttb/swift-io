//
//  IO.Blocking.Lane.shared.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 29/12/2025.
//

extension IO.Blocking.Lane {
    /// The shared default lane for blocking I/O operations.
    ///
    /// This instance is lazily initialized and process-scoped:
    /// - Uses a `Threads` lane with default options
    /// - Does **not** require `shutdown()` (process-scoped)
    /// - Suitable for the common case where you need simple blocking I/O
    ///
    /// ## Usage
    /// ```swift
    /// // Direct use
    /// let result = try await IO.Blocking.Lane.shared.run { blockingOperation() }
    ///
    /// // Pass to components that need a lane
    /// let fs = File.System.Async(lane: .shared)
    /// let pool = IO.Executor.Pool(lane: .shared)
    /// ```
    ///
    /// ## Lifecycle
    /// The shared lane is a process-global singleton. It should generally
    /// not be shut down during normal operation.
    ///
    /// For advanced use cases (custom thread count, explicit lifecycle),
    /// create your own lane with `IO.Blocking.Lane.threads(options)`.
    public static let shared: IO.Blocking.Lane = .threads(.init())
}
