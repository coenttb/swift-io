//
//  IO.Executor.Synchronization.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 28/12/2025.
//

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#elseif os(Windows)
    import WinSDK
#endif

extension IO.Executor {
    /// Internal synchronization primitive for executor job queue.
    ///
    /// Single mutex + single condition variable, minimal API.
    ///
    /// ## Safety
    /// This type is `@unchecked Sendable` because it provides internal synchronization.
    /// All access to protected data must occur within `withLock` or while holding the lock.
    final class Synchronization: @unchecked Sendable {

        // This is intentionally separate from `IO.Blocking.Threads.Lock` which has
        // two condition variables for worker/deadline coordination.
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
                var mutexAttr = pthread_mutexattr_t()
                pthread_mutexattr_init(&mutexAttr)
                pthread_mutex_init(&mutex, &mutexAttr)
                pthread_mutexattr_destroy(&mutexAttr)

                var condAttr = pthread_condattr_t()
                pthread_condattr_init(&condAttr)
                #if !os(macOS) && !os(iOS) && !os(tvOS) && !os(watchOS)
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

        /// Acquire the lock.
        func lock() {
            #if os(Windows)
                AcquireSRWLockExclusive(&srwlock)
            #else
                pthread_mutex_lock(&mutex)
            #endif
        }

        /// Release the lock.
        func unlock() {
            #if os(Windows)
                ReleaseSRWLockExclusive(&srwlock)
            #else
                pthread_mutex_unlock(&mutex)
            #endif
        }

        /// Execute a closure while holding the lock.
        func withLock<T>(_ body: () -> T) -> T {
            lock()
            defer { unlock() }
            return body()
        }

        // MARK: - Condition Variable Operations

        /// Wait on the condition variable. Must be called while holding the lock.
        ///
        /// The lock is released while waiting and reacquired before returning.
        func wait() {
            #if os(Windows)
                _ = SleepConditionVariableSRW(&condvar, &srwlock, INFINITE, 0)
            #else
                pthread_cond_wait(&cond, &mutex)
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
