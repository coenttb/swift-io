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

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#elseif os(Windows)
    import WinSDK
#endif

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
        #if os(Windows)
            private var srwlock: SRWLOCK = SRWLOCK()
            private var workerCondvar: CONDITION_VARIABLE = CONDITION_VARIABLE()
            private var deadlineCondvar: CONDITION_VARIABLE = CONDITION_VARIABLE()
        #else
            private var mutex: pthread_mutex_t = pthread_mutex_t()
            private var workerCond: pthread_cond_t = pthread_cond_t()
            private var deadlineCond: pthread_cond_t = pthread_cond_t()
        #endif

        init() {
            #if os(Windows)
                InitializeSRWLock(&srwlock)
                InitializeConditionVariable(&workerCondvar)
                InitializeConditionVariable(&deadlineCondvar)
            #else
                // Initialize mutex
                var mutexAttr = pthread_mutexattr_t()
                pthread_mutexattr_init(&mutexAttr)
                pthread_mutex_init(&mutex, &mutexAttr)
                pthread_mutexattr_destroy(&mutexAttr)

                // Initialize worker condvar
                var condAttr = pthread_condattr_t()
                pthread_condattr_init(&condAttr)
                #if !os(macOS) && !os(iOS) && !os(tvOS) && !os(watchOS)
                    pthread_condattr_setclock(&condAttr, CLOCK_MONOTONIC)
                #endif
                pthread_cond_init(&workerCond, &condAttr)

                // Initialize deadline condvar (reuse attributes)
                pthread_cond_init(&deadlineCond, &condAttr)
                pthread_condattr_destroy(&condAttr)
            #endif
        }

        deinit {
            #if !os(Windows)
                pthread_cond_destroy(&deadlineCond)
                pthread_cond_destroy(&workerCond)
                pthread_mutex_destroy(&mutex)
            #endif
        }

        // MARK: - Lock Operations

        func withLock<T, E: Error>(_ body: () throws(E) -> T) throws(E) -> T {
            #if os(Windows)
                AcquireSRWLockExclusive(&srwlock)
                defer { ReleaseSRWLockExclusive(&srwlock) }
            #else
                pthread_mutex_lock(&mutex)
                defer { pthread_mutex_unlock(&mutex) }
            #endif
            return try body()
        }

        func lock() {
            #if os(Windows)
                AcquireSRWLockExclusive(&srwlock)
            #else
                pthread_mutex_lock(&mutex)
            #endif
        }

        func unlock() {
            #if os(Windows)
                ReleaseSRWLockExclusive(&srwlock)
            #else
                pthread_mutex_unlock(&mutex)
            #endif
        }

        // MARK: - Shutdown Helper

        /// Broadcast to both worker and deadline condition variables.
        /// Used during shutdown to wake all waiting threads.
        func broadcastAll() {
            worker.broadcast()
            deadline.broadcast()
        }

        // MARK: - Nested Accessors

        /// Accessor for worker condition variable operations.
        ///
        /// Provides a cleaner API: `lock.worker.wait()` instead of `lock.waitWorker()`.
        var worker: Worker { Worker(self) }

        /// Accessor for deadline condition variable operations.
        ///
        /// Provides a cleaner API: `lock.deadline.wait()` instead of `lock.waitDeadline()`.
        var deadline: Deadline { Deadline(self) }
    }
}

// MARK: - Lock.Worker

extension IO.Blocking.Threads.Lock {
    /// Accessor for worker condition variable operations.
    ///
    /// ## Usage
    /// ```swift
    /// lock.worker.wait()
    /// lock.worker.signal()
    /// lock.worker.broadcast()
    /// ```
    struct Worker {
        private let _lock: IO.Blocking.Threads.Lock

        fileprivate init(_ lock: IO.Blocking.Threads.Lock) {
            self._lock = lock
        }

        /// Wait on the worker condition. Must be called while holding the lock.
        func wait() {
            #if os(Windows)
                _ = SleepConditionVariableSRW(&_lock.workerCondvar, &_lock.srwlock, INFINITE, 0)
            #else
                pthread_cond_wait(&_lock.workerCond, &_lock.mutex)
            #endif
        }

        /// Wait on the worker condition with a timeout. Must be called while holding the lock.
        ///
        /// - Parameter nanoseconds: Maximum wait time in nanoseconds.
        /// - Returns: `true` if signaled, `false` if timed out.
        func wait(timeoutNanoseconds nanoseconds: UInt64) -> Bool {
            #if os(Windows)
                // Ceiling division to avoid under-waiting; clamp to DWORD.max
                let milliseconds = (nanoseconds + 999_999) / 1_000_000
                let result = SleepConditionVariableSRW(
                    &_lock.workerCondvar,
                    &_lock.srwlock,
                    DWORD(min(milliseconds, UInt64(DWORD.max))),
                    0
                )
                return result
            #elseif os(macOS) || os(iOS) || os(tvOS) || os(watchOS)
                // Darwin: use relative timed wait (immune to wall-clock changes)
                var ts = timespec()
                ts.tv_sec = Int(nanoseconds / 1_000_000_000)
                ts.tv_nsec = Int(nanoseconds % 1_000_000_000)
                let result = pthread_cond_timedwait_relative_np(&_lock.workerCond, &_lock.mutex, &ts)
                return result == 0
            #else
                // Linux: condvar configured with CLOCK_MONOTONIC
                var ts = timespec()
                clock_gettime(CLOCK_MONOTONIC, &ts)
                let seconds = nanoseconds / 1_000_000_000
                let remainingNanos = nanoseconds % 1_000_000_000
                ts.tv_sec += Int(seconds)
                ts.tv_nsec += Int(remainingNanos)
                if ts.tv_nsec >= 1_000_000_000 {
                    ts.tv_sec += 1
                    ts.tv_nsec -= 1_000_000_000
                }
                let result = pthread_cond_timedwait(&_lock.workerCond, &_lock.mutex, &ts)
                return result == 0
            #endif
        }

        /// Signal one worker thread.
        func signal() {
            #if os(Windows)
                WakeConditionVariable(&_lock.workerCondvar)
            #else
                pthread_cond_signal(&_lock.workerCond)
            #endif
        }

        /// Signal all worker threads.
        func broadcast() {
            #if os(Windows)
                WakeAllConditionVariable(&_lock.workerCondvar)
            #else
                pthread_cond_broadcast(&_lock.workerCond)
            #endif
        }
    }
}

// MARK: - Lock.Deadline

extension IO.Blocking.Threads.Lock {
    /// Accessor for deadline condition variable operations.
    ///
    /// ## Usage
    /// ```swift
    /// lock.deadline.wait()
    /// lock.deadline.signal()
    /// lock.deadline.broadcast()
    /// ```
    struct Deadline {
        private let _lock: IO.Blocking.Threads.Lock

        fileprivate init(_ lock: IO.Blocking.Threads.Lock) {
            self._lock = lock
        }

        /// Wait on the deadline condition. Must be called while holding the lock.
        func wait() {
            #if os(Windows)
                _ = SleepConditionVariableSRW(&_lock.deadlineCondvar, &_lock.srwlock, INFINITE, 0)
            #else
                pthread_cond_wait(&_lock.deadlineCond, &_lock.mutex)
            #endif
        }

        /// Wait on the deadline condition with a timeout. Must be called while holding the lock.
        ///
        /// - Parameter nanoseconds: Maximum wait time in nanoseconds.
        /// - Returns: `true` if signaled, `false` if timed out.
        func wait(timeoutNanoseconds nanoseconds: UInt64) -> Bool {
            #if os(Windows)
                // Ceiling division to avoid under-waiting; clamp to DWORD.max
                let milliseconds = (nanoseconds + 999_999) / 1_000_000
                let result = SleepConditionVariableSRW(
                    &_lock.deadlineCondvar,
                    &_lock.srwlock,
                    DWORD(min(milliseconds, UInt64(DWORD.max))),
                    0
                )
                return result
            #elseif os(macOS) || os(iOS) || os(tvOS) || os(watchOS)
                // Darwin: use relative timed wait (immune to wall-clock changes)
                var ts = timespec()
                ts.tv_sec = Int(nanoseconds / 1_000_000_000)
                ts.tv_nsec = Int(nanoseconds % 1_000_000_000)
                let result = pthread_cond_timedwait_relative_np(&_lock.deadlineCond, &_lock.mutex, &ts)
                return result == 0
            #else
                // Linux: condvar configured with CLOCK_MONOTONIC
                var ts = timespec()
                clock_gettime(CLOCK_MONOTONIC, &ts)
                let seconds = nanoseconds / 1_000_000_000
                let remainingNanos = nanoseconds % 1_000_000_000
                ts.tv_sec += Int(seconds)
                ts.tv_nsec += Int(remainingNanos)
                if ts.tv_nsec >= 1_000_000_000 {
                    ts.tv_sec += 1
                    ts.tv_nsec -= 1_000_000_000
                }
                let result = pthread_cond_timedwait(&_lock.deadlineCond, &_lock.mutex, &ts)
                return result == 0
            #endif
        }

        /// Signal the deadline manager thread.
        func signal() {
            #if os(Windows)
                WakeConditionVariable(&_lock.deadlineCondvar)
            #else
                pthread_cond_signal(&_lock.deadlineCond)
            #endif
        }

        /// Signal all deadline waiters (used for shutdown).
        func broadcast() {
            #if os(Windows)
                WakeAllConditionVariable(&_lock.deadlineCondvar)
            #else
                pthread_cond_broadcast(&_lock.deadlineCond)
            #endif
        }
    }
}
