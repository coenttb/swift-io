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
    /// A mutex + condition variable pair for thread coordination.
    ///
    /// ## Safety Invariant
    /// - All access to protected data occurs within `withLock`.
    /// - Wait operations must be called within locked context.
    final class Lock: @unchecked Sendable {
        #if os(Windows)
            private var srwlock: SRWLOCK = SRWLOCK()
            private var condvar: CONDITION_VARIABLE = CONDITION_VARIABLE()
        #else
            private var mutex: pthread_mutex_t = pthread_mutex_t()
            private var cond: pthread_cond_t = pthread_cond_t()
        #endif

        init() {
            #if os(Windows)
                InitializeSRWLock(&srwlock)
                InitializeConditionVariable(&condvar)
            #else
                // Initialize mutex
                var mutexAttr = pthread_mutexattr_t()
                pthread_mutexattr_init(&mutexAttr)
                pthread_mutex_init(&mutex, &mutexAttr)
                pthread_mutexattr_destroy(&mutexAttr)

                // Initialize condvar with CLOCK_MONOTONIC for timed waits
                // This prevents issues with system clock adjustments (NTP, DST, etc.)
                var condAttr = pthread_condattr_t()
                pthread_condattr_init(&condAttr)
                #if !os(macOS) && !os(iOS) && !os(tvOS) && !os(watchOS)
                    // Linux: set CLOCK_MONOTONIC for condvar
                    pthread_condattr_setclock(&condAttr, CLOCK_MONOTONIC)
                #endif
                pthread_cond_init(&cond, &condAttr)
                pthread_condattr_destroy(&condAttr)
            #endif
        }

        deinit {
            #if !os(Windows)
                pthread_cond_destroy(&cond)
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

        // MARK: - Condition Operations

        /// Wait on the condition. Must be called while holding the lock.
        func wait() {
            #if os(Windows)
                _ = SleepConditionVariableSRW(&condvar, &srwlock, INFINITE, 0)
            #else
                pthread_cond_wait(&cond, &mutex)
            #endif
        }

        /// Wait on the condition with a timeout. Must be called while holding the lock.
        ///
        /// - Parameter nanoseconds: Maximum wait time in nanoseconds.
        /// - Returns: `true` if signaled, `false` if timed out.
        func wait(timeoutNanoseconds nanoseconds: UInt64) -> Bool {
            #if os(Windows)
                let milliseconds = nanoseconds / 1_000_000
                let result = SleepConditionVariableSRW(
                    &condvar,
                    &srwlock,
                    DWORD(min(milliseconds, UInt64(DWORD.max))),
                    0
                )
                return result
            #elseif os(macOS) || os(iOS) || os(tvOS) || os(watchOS)
                // Darwin: condvar uses wall clock (no monotonic support)
                var ts = timespec()
                clock_gettime(CLOCK_REALTIME, &ts)
                let seconds = nanoseconds / 1_000_000_000
                let remainingNanos = nanoseconds % 1_000_000_000
                ts.tv_sec += Int(seconds)
                ts.tv_nsec += Int(remainingNanos)
                if ts.tv_nsec >= 1_000_000_000 {
                    ts.tv_sec += 1
                    ts.tv_nsec -= 1_000_000_000
                }
                let result = pthread_cond_timedwait(&cond, &mutex, &ts)
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
                let result = pthread_cond_timedwait(&cond, &mutex, &ts)
                return result == 0
            #endif
        }

        /// Signal one waiting thread.
        func signal() {
            #if os(Windows)
                WakeConditionVariable(&condvar)
            #else
                pthread_cond_signal(&cond)
            #endif
        }

        /// Signal all waiting threads.
        func broadcast() {
            #if os(Windows)
                WakeAllConditionVariable(&condvar)
            #else
                pthread_cond_broadcast(&cond)
            #endif
        }
    }
}
