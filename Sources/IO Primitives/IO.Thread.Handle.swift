//
//  IO.Thread.Handle.swift
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

extension IO.Thread {
    /// Opaque handle to an OS thread.
    ///
    /// ## Move-Only Semantics
    /// This type is `~Copyable` to enforce exactly-once `join()` semantics.
    /// Copying the handle would allow double-join, which is undefined behavior
    /// on all platforms (double `CloseHandle` on Windows, double `pthread_join` on POSIX).
    ///
    /// ## Safety
    /// This type is `@unchecked Sendable` because the underlying handle
    /// (pthread_t or HANDLE) can be safely passed between threads.
    /// The move-only constraint ensures exactly-once consumption.
    public struct Handle: ~Copyable, @unchecked Sendable {
        #if os(Windows)
            private let handle: HANDLE

            init(handle: HANDLE) {
                self.handle = handle
            }
        #else
            private let thread: pthread_t

            init(thread: pthread_t) {
                self.thread = thread
            }
        #endif
    }
}

extension IO.Thread.Handle {
    /// Wait for the thread to complete and release the handle.
    ///
    /// This is a consuming operation - the handle cannot be used after calling `join()`.
    /// On Windows, this calls `WaitForSingleObject` then `CloseHandle`.
    /// On POSIX, this calls `pthread_join`.
    ///
    /// - Precondition: Must NOT be called from this thread (deadlock).
    /// - Note: Must be called exactly once. The `~Copyable` constraint enforces this.
    public consuming func join() {
        precondition(
            isCurrentThread == false,
            "IO.Thread.Handle.join() called on the current thread"
        )
        #if os(Windows)
            let result = WaitForSingleObject(handle, INFINITE)
            precondition(result == WAIT_OBJECT_0, "WaitForSingleObject failed: \(result)")
            let ok = CloseHandle(handle)
            precondition(ok, "CloseHandle failed")
        #else
            let result = pthread_join(thread, nil)
            precondition(result == 0, "pthread_join failed: \(result)")
        #endif
    }

    /// Check if the current thread is this thread.
    ///
    /// Used for shutdown safety to prevent join-on-self deadlock.
    public var isCurrentThread: Bool {
        #if os(Windows)
            GetCurrentThreadId() == GetThreadId(handle)
        #else
            pthread_equal(pthread_self(), thread) != 0
        #endif
    }
}
