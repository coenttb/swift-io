//
//  IO.Executor.shared.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 28/12/2025.
//

extension IO.Executor {
    /// The shared executor pool for Pool actors.
    ///
    /// Lazily initialized on first access. Default configuration:
    /// min(4, processorCount) executor threads.
    ///
    /// ## Usage
    /// Pool actors automatically obtain an executor from this shared pool
    /// via round-robin assignment at creation time.
    ///
    /// ## Lifecycle
    /// The shared pool is a process-global singleton. It should generally
    /// not be shut down during normal operation.
    public static let shared: Threads = Threads()
}
