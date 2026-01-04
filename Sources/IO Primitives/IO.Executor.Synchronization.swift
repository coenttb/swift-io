//
//  IO.Executor.Synchronization.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 28/12/2025.
//

public import Kernel

extension IO.Executor {
    /// Internal synchronization primitive for executor job queue.
    ///
    /// Single mutex + single condition variable, minimal API.
    /// Uses `Kernel.Thread.Mutex` and `Kernel.Thread.Condition`.
    ///
    /// ## Safety
    /// This type is `@unchecked Sendable` because it provides internal synchronization.
    /// All access to protected data must occur within `withLock` or while holding the lock.
    final class Synchronization: @unchecked Sendable {
        private let mutex = Kernel.Thread.Mutex()
        private let condition = Kernel.Thread.Condition()

        init() {}

        // MARK: - Lock Operations

        /// Acquire the lock.
        @usableFromInline
        func lock() {
            mutex.lock()
        }

        /// Release the lock.
        @usableFromInline
        func unlock() {
            mutex.unlock()
        }

        /// Execute a closure while holding the lock.
        @usableFromInline
        func withLock<T>(_ body: () -> T) -> T {
            mutex.withLock(body)
        }

        // MARK: - Condition Variable Operations

        /// Wait on the condition variable. Must be called while holding the lock.
        ///
        /// The lock is released while waiting and reacquired before returning.
        @usableFromInline
        func wait() {
            condition.wait(mutex: mutex)
        }

        /// Signal one waiting thread.
        @usableFromInline
        func signal() {
            condition.signal()
        }

        /// Signal all waiting threads.
        @usableFromInline
        func broadcast() {
            condition.broadcast()
        }
    }
}
