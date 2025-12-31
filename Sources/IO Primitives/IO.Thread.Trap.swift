//
//  IO.Thread.Trap.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 30/12/2025.
//

extension IO.Thread {
    /// Trapping thread spawn policy.
    ///
    /// Use this when thread creation failure is unrecoverable for the caller
    /// (e.g. executors, runtimes). Prefer `IO.Thread.spawn` when you can propagate
    /// `IO.Thread.Spawn.Error`.
    ///
    /// ## Usage
    /// ```swift
    /// let handle = IO.Thread.trap { print("Hello from thread") }
    /// handle.join()
    /// ```
    ///
    /// ## Policy
    /// This callable traps (via `fatalError`) if thread creation fails.
    /// The diagnostic message includes the platform error code for debugging.
    public struct Trap: Sendable {
        @usableFromInline
        init() {}
    }

    /// Trapping thread spawn entry point.
    ///
    /// Usage:
    /// ```swift
    /// let handle = IO.Thread.trap { ... }
    /// ```
    public static var trap: Trap { Trap() }
}

extension IO.Thread.Trap {
    /// Spawns a dedicated OS thread, trapping on failure.
    ///
    /// - Parameter body: The work to run on the new thread. Executed exactly once.
    /// - Returns: An opaque handle to the thread.
    @inlinable
    public func callAsFunction(
        _ body: @escaping @Sendable () -> Void
    ) -> IO.Thread.Handle {
        do { return try IO.Thread.spawn(body) } catch { fatalError(error.description) }
    }

    /// Spawns a dedicated OS thread with an explicit value, trapping on failure.
    ///
    /// - Parameters:
    ///   - value: A value to pass to the thread. Ownership is transferred.
    ///   - body: The work to run, receiving the value. Executed exactly once.
    /// - Returns: An opaque handle to the thread.
    @inlinable
    public func callAsFunction<T: ~Copyable>(
        _ value: consuming T,
        _ body: @escaping @Sendable (consuming T) -> Void
    ) -> IO.Thread.Handle {
        do { return try IO.Thread.spawn(value, body) } catch { fatalError(error.description) }
    }
}
