//
//  IO.Executor.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 24/12/2025.
//

import Kernel

extension IO {
    /// Namespace for executor types.
    ///
    /// Provides infrastructure for actor-based resource management:
    /// - `Pool`: Actor-based pool for managing resources with handles
    /// - `Shards`: Sharded collection of pools for concurrent access
    /// - `Handle`: Opaque resource references with scoped validity
    /// - `Slot`: Cross-await-boundary bridging for ~Copyable resources
    /// - `Transaction`: Exclusive access to pooled resources
    internal enum Executor {}
}

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
    /// - **Process-scoped singleton**: Lives for the entire process lifetime.
    /// - **No shutdown required**: The pool cleans up automatically on process exit.
    /// - **Thread-safe**: Access from any thread is safe via `@unchecked Sendable`.
    ///
    /// ## Global State (PATTERN REQUIREMENTS §6.6)
    /// This is an intentional process-global singleton. Rationale:
    /// - Executor threads are expensive resources (kernel threads)
    /// - Sharing executors across Pool actors reduces resource waste
    /// - Round-robin assignment provides load balancing
    /// - Testable: Create a separate `Threads` instance for isolated tests
    internal static let shared: Kernel.Thread.Executors = Kernel.Thread.Executors()
}
