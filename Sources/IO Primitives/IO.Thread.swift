//
//  IO.Thread.swift
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

extension IO {
    /// Namespace for thread-related primitives.
    public enum Thread {}
}

// MARK: - Handle

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

        /// Wait for the thread to complete.
        public func join() {
            WaitForSingleObject(handle, INFINITE)
            CloseHandle(handle)
        }

        /// Check if the current thread is this thread.
        ///
        /// Used for shutdown safety to prevent join-on-self deadlock.
        public var isCurrentThread: Bool {
            GetCurrentThreadId() == GetThreadId(handle)
        }
        #else
        let thread: pthread_t

        init(thread: pthread_t) {
            self.thread = thread
        }

        /// Wait for the thread to complete.
        public func join() {
            pthread_join(thread, nil)
        }

        /// Check if the current thread is this thread.
        ///
        /// Used for shutdown safety to prevent join-on-self deadlock.
        public var isCurrentThread: Bool {
            pthread_equal(pthread_self(), thread) != 0
        }
        #endif
    }
}

// MARK: - Spawn

extension IO.Thread {
    /// Spawns a dedicated OS thread.
    ///
    /// The closure is invoked exactly once on the spawned OS thread.
    /// This guarantee is essential for ownership-transfer patterns using
    /// `IO.RetainedPointer`, where the closure takes ownership of a retained
    /// reference that must be released exactly once.
    ///
    /// - Parameter body: The work to run on the new thread. Executed exactly once.
    /// - Returns: An opaque handle to the thread.
    public static func spawn(_ body: @escaping @Sendable () -> Void) -> Handle {
        #if os(Windows)
        var threadHandle: HANDLE?
        let context = UnsafeMutablePointer<(@Sendable () -> Void)>.allocate(capacity: 1)
        context.initialize(to: body)

        threadHandle = CreateThread(
            nil,
            0,
            { context in
                guard let ctx = context else { return 0 }
                let body = ctx.assumingMemoryBound(to: (@Sendable () -> Void).self)
                let work = body.move()
                body.deallocate()
                work()
                return 0
            },
            context,
            0,
            nil
        )
        return Handle(handle: threadHandle!)
        #elseif canImport(Darwin)
        var thread: pthread_t?
        let contextPtr = UnsafeMutablePointer<(@Sendable () -> Void)>.allocate(capacity: 1)
        contextPtr.initialize(to: body)

        pthread_create(
            &thread,
            nil,
            { ctx in
                let bodyPtr = ctx.assumingMemoryBound(to: (@Sendable () -> Void).self)
                let work = bodyPtr.move()
                bodyPtr.deallocate()
                work()
                return nil
            },
            contextPtr
        )

        return Handle(thread: thread!)
        #else
        // Linux: pthread_t is non-optional
        var thread: pthread_t = 0
        let contextPtr = UnsafeMutablePointer<(@Sendable () -> Void)>.allocate(capacity: 1)
        contextPtr.initialize(to: body)

        pthread_create(
            &thread,
            nil,
            { ctx in
                guard let ctx else { return nil }
                let bodyPtr = ctx.assumingMemoryBound(to: (@Sendable () -> Void).self)
                let work = bodyPtr.move()
                bodyPtr.deallocate()
                work()
                return nil
            },
            contextPtr
        )

        return Handle(thread: thread)
        #endif
    }

    /// Spawns a dedicated OS thread with an explicit value.
    ///
    /// This variant accepts a `~Copyable` value that is passed to the closure,
    /// avoiding closure capture issues with move-only types. The value is
    /// transferred using `IO.Handoff.Cell`, the single audited mechanism for
    /// cross-boundary ownership transfer.
    ///
    /// The closure is invoked exactly once on the spawned OS thread.
    ///
    /// - Parameters:
    ///   - value: A value to pass to the thread. Ownership is transferred.
    ///   - body: The work to run, receiving the value. Executed exactly once.
    /// - Returns: An opaque handle to the thread.
    ///
    /// - Note: Either starts the thread and runs exactly once, or traps on
    ///   thread creation failure. Storage cleanup is guaranteed on success.
    public static func spawn<T: ~Copyable>(
        _ value: consuming T,
        _ body: @escaping @Sendable (consuming T) -> Void
    ) -> Handle {
        // Use IO.Handoff for cross-boundary ownership transfer
        let cell = IO.Handoff.Cell(value)
        let token = cell.token()

        return spawn {
            let v = IO.Handoff.Cell<T>.take(token)
            body(v)
        }
    }
}
