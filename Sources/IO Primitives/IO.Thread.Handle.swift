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
    /// ## Safety
    /// This type is `@unchecked Sendable` because the underlying handle
    /// (pthread_t or HANDLE) can be safely passed between threads.
    public struct Handle: @unchecked Sendable {
        #if os(Windows)
            let handle: HANDLE

            init(handle: HANDLE) {
                self.handle = handle
            }
        #else
            let thread: pthread_t

            init(thread: pthread_t) {
                self.thread = thread
            }
        #endif
    }
}

extension IO.Thread.Handle {
    /// Wait for the thread to complete.
    public func join() {
        #if os(Windows)
            WaitForSingleObject(handle, INFINITE)
            CloseHandle(handle)
        #else
            pthread_join(thread, nil)
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
