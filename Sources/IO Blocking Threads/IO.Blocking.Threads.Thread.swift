//
//  IO.Blocking.Threads.Thread.swift
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

extension IO.Blocking.Threads {
    /// Namespace for thread-related types.
    public enum Thread {}
}

extension IO.Blocking.Threads.Thread {
    /// Spawns a dedicated OS thread.
    ///
    /// - Parameter body: The work to run on the new thread.
    /// - Returns: An opaque handle to the thread.
    static func spawn(_ body: @escaping @Sendable () -> Void) -> Handle {
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
}
