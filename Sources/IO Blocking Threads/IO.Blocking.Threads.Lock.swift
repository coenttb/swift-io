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

public import Kernel

extension IO.Blocking.Threads {
    /// A mutex with two condition variables for thread coordination.
    ///
    /// ## Design
    /// Two separate condition variables prevent cross-wake interference:
    /// - `workerCond`: Workers wait for jobs to be enqueued
    /// - `deadlineCond`: Deadline manager waits for deadline changes
    ///
    /// This ensures `signal()` wakes the intended waiter type, avoiding
    /// starvation when workers and deadline manager share a mutex.
    ///
    /// ## Safety Invariant
    /// - All access to protected data occurs within `withLock`.
    /// - Wait operations must be called within locked context.
    final class Lock: @unchecked Sendable {
        private let mutex: Kernel.Thread.Mutex
        private let workerCond: Kernel.Thread.Condition
        private let deadlineCond: Kernel.Thread.Condition

        init() {
            self.mutex = Kernel.Thread.Mutex()
            self.workerCond = Kernel.Thread.Condition()
            self.deadlineCond = Kernel.Thread.Condition()
        }

        // No deinit needed - Kernel types handle their own cleanup

        // MARK: - Lock Operations

        func withLock<T, E: Error>(_ body: () throws(E) -> T) throws(E) -> T {
            mutex.lock()
            defer { mutex.unlock() }
            return try body()
        }

        func lock() {
            mutex.lock()
        }

        func unlock() {
            mutex.unlock()
        }

        // MARK: - Worker Condition Accessor

        /// Namespace for worker condition variable operations.
        struct Worker {
            unowned let lock: Lock

            init(_ lock: Lock) {
                self.lock = lock
            }

            /// Wait on the worker condition. Must be called while holding the lock.
            func wait() {
                lock.workerCond.wait(mutex: lock.mutex)
            }

            /// Wait on the worker condition with a timeout. Must be called while holding the lock.
            ///
            /// - Parameter nanoseconds: Maximum wait time in nanoseconds.
            /// - Returns: `true` if signaled, `false` if timed out.
            func wait(timeout nanoseconds: UInt64) -> Bool {
                lock.workerCond.wait(mutex: lock.mutex, timeout: .nanoseconds(Int64(nanoseconds)))
            }

            /// Signal one worker thread.
            func signal() {
                lock.workerCond.signal()
            }

            /// Signal all worker threads.
            func broadcast() {
                lock.workerCond.broadcast()
            }
        }

        /// Access worker condition variable operations.
        var worker: Worker { Worker(self) }

        // MARK: - Deadline Condition Accessor

        /// Namespace for deadline condition variable operations.
        struct Deadline {
            unowned let lock: Lock

            init(_ lock: Lock) {
                self.lock = lock
            }

            /// Wait on the deadline condition. Must be called while holding the lock.
            func wait() {
                lock.deadlineCond.wait(mutex: lock.mutex)
            }

            /// Wait on the deadline condition with a timeout. Must be called while holding the lock.
            ///
            /// - Parameter nanoseconds: Maximum wait time in nanoseconds.
            /// - Returns: `true` if signaled, `false` if timed out.
            func wait(timeout nanoseconds: UInt64) -> Bool {
                lock.deadlineCond.wait(mutex: lock.mutex, timeout: .nanoseconds(Int64(nanoseconds)))
            }

            /// Signal the deadline manager thread.
            func signal() {
                lock.deadlineCond.signal()
            }

            /// Signal all deadline waiters (used for shutdown).
            func broadcast() {
                lock.deadlineCond.broadcast()
            }
        }

        /// Access deadline condition variable operations.
        var deadline: Deadline { Deadline(self) }

        // MARK: - Broadcast Accessor

        /// Accessor for broadcast operations.
        struct Broadcast {
            unowned let lock: Lock

            /// Broadcast to both worker and deadline condition variables.
            /// Used during shutdown to wake all waiting threads.
            func all() {
                lock.worker.broadcast()
                lock.deadline.broadcast()
            }

            /// Broadcast to both worker and deadline condition variables.
            func callAsFunction() {
                all()
            }
        }

        /// Accessor for broadcast operations.
        var broadcast: Broadcast { Broadcast(lock: self) }
    }
}
