//
//  IO.Blocking.Threads.Thread.Handle.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 24/12/2025.
//

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#elseif os(Windows)
    import WinSDK
#endif

extension IO.Blocking.Threads.Thread {
    /// Opaque handle to an OS thread.
    struct Handle: @unchecked Sendable {
        #if os(Windows)
            let handle: HANDLE

            init(handle: HANDLE) {
                self.handle = handle
            }

            func join() {
                WaitForSingleObject(handle, INFINITE)
                CloseHandle(handle)
            }
        #else
            let thread: pthread_t

            init(thread: pthread_t) {
                self.thread = thread
            }

            func join() {
                pthread_join(thread, nil)
            }
        #endif
    }
}
