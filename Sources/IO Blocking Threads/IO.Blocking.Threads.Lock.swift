//
//  IO.Blocking.Threads.Lock.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 24/12/2025.
//

// MARK: - Safety Invariant
//
// This file contains @unchecked Sendable types.
// All primitives here are low-level OS wrappers with internal synchronization.
// They are used only by the Threads lane implementation.

extension IO.Blocking.Threads {
    /// A mutex with two condition variables for thread coordination.
    ///
    /// Uses `Kernel.Thread.Executor.Synchronization<2>` internally:
    /// - Condition 0: Workers wait for jobs to be enqueued
    /// - Condition 1: Deadline manager waits for deadline changes
    ///
    /// This ensures `signal()` wakes the intended waiter type, avoiding
    /// starvation when workers and deadline manager share a mutex.
    ///
    /// ## Safety Invariant
    /// - All access to protected data occurs within `withLock`.
    /// - Wait operations must be called within locked context.
    typealias Lock = Kernel.Thread.Executor.DualSync
}
