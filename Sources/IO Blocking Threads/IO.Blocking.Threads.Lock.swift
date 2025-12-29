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

        // MARK: - Worker Condition Operations

        /// Wait on the worker condition. Must be called while holding the lock.
        func waitWorker() {
            #if os(Windows)
                _ = SleepConditionVariableSRW(&workerCondvar, &srwlock, INFINITE, 0)
            #else
                pthread_cond_wait(&workerCond, &mutex)
            #endif
        }

        /// Wait on the worker condition with a timeout. Must be called while holding the lock.
        ///
        /// - Parameter nanoseconds: Maximum wait time in nanoseconds.
        /// - Returns: `true` if signaled, `false` if timed out.
        func waitWorker(timeoutNanoseconds nanoseconds: UInt64) -> Bool {
            #if os(Windows)
                // Ceiling division to avoid under-waiting; clamp to DWORD.max
                let milliseconds = (nanoseconds + 999_999) / 1_000_000
                let result = SleepConditionVariableSRW(
                    &workerCondvar,
                    &srwlock,
                    DWORD(min(milliseconds, UInt64(DWORD.max))),
                    0
                )
                return result
            #elseif os(macOS) || os(iOS) || os(tvOS) || os(watchOS)
                // Darwin: use relative timed wait (immune to wall-clock changes)
                var ts = timespec()
                ts.tv_sec = Int(nanoseconds / 1_000_000_000)
                ts.tv_nsec = Int(nanoseconds % 1_000_000_000)
                let result = pthread_cond_timedwait_relative_np(&workerCond, &mutex, &ts)
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
                let result = pthread_cond_timedwait(&workerCond, &mutex, &ts)
                return result == 0
            #endif
        }

        /// Signal one worker thread.
        func signalWorker() {
            #if os(Windows)
                WakeConditionVariable(&workerCondvar)
            #else
                pthread_cond_signal(&workerCond)
            #endif
        }

        /// Signal all worker threads.
        func broadcastWorker() {
            #if os(Windows)
                WakeAllConditionVariable(&workerCondvar)
            #else
                pthread_cond_broadcast(&workerCond)
            #endif
        }

        // MARK: - Deadline Condition Operations

        /// Wait on the deadline condition. Must be called while holding the lock.
        func waitDeadline() {
            #if os(Windows)
                _ = SleepConditionVariableSRW(&deadlineCondvar, &srwlock, INFINITE, 0)
            #else
                pthread_cond_wait(&deadlineCond, &mutex)
            #endif
        }

        /// Wait on the deadline condition with a timeout. Must be called while holding the lock.
        ///
        /// - Parameter nanoseconds: Maximum wait time in nanoseconds.
        /// - Returns: `true` if signaled, `false` if timed out.
        func waitDeadline(timeoutNanoseconds nanoseconds: UInt64) -> Bool {
            #if os(Windows)
                // Ceiling division to avoid under-waiting; clamp to DWORD.max
                let milliseconds = (nanoseconds + 999_999) / 1_000_000
                let result = SleepConditionVariableSRW(
                    &deadlineCondvar,
                    &srwlock,
                    DWORD(min(milliseconds, UInt64(DWORD.max))),
                    0
                )
                return result
            #elseif os(macOS) || os(iOS) || os(tvOS) || os(watchOS)
                // Darwin: use relative timed wait (immune to wall-clock changes)
                var ts = timespec()
                ts.tv_sec = Int(nanoseconds / 1_000_000_000)
                ts.tv_nsec = Int(nanoseconds % 1_000_000_000)
                let result = pthread_cond_timedwait_relative_np(&deadlineCond, &mutex, &ts)
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
                let result = pthread_cond_timedwait(&deadlineCond, &mutex, &ts)
                return result == 0
            #endif
        }

        /// Signal the deadline manager thread.
        func signalDeadline() {
            #if os(Windows)
                WakeConditionVariable(&deadlineCondvar)
            #else
                pthread_cond_signal(&deadlineCond)
            #endif
        }

        /// Signal all deadline waiters (used for shutdown).
        func broadcastDeadline() {
            #if os(Windows)
                WakeAllConditionVariable(&deadlineCondvar)
            #else
                pthread_cond_broadcast(&deadlineCond)
            #endif
        }

        // MARK: - Shutdown Helper

        /// Broadcast to both worker and deadline condition variables.
        /// Used during shutdown to wake all waiting threads.
        func broadcastAll() {
            broadcastWorker()
            broadcastDeadline()
        }
    }
}
