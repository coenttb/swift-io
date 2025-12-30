//
//  IO.Thread.Spawn.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 30/12/2025.
//

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#elseif os(Windows)
    import WinSDK
#endif

extension IO.Thread {
    /// Thread spawning callable type.
    ///
    /// Provides a clean `IO.Thread.spawn { ... }` syntax via `callAsFunction`.
    ///
    /// ## Usage
    /// ```swift
    /// // Throwing (preferred for robust code)
    /// let handle = try IO.Thread.spawn { print("Hello from thread") }
    ///
    /// // With value transfer
    /// let handle = try IO.Thread.spawn(myValue) { value in
    ///     process(value)
    /// }
    /// ```
    ///
    /// ## Failure Handling
    /// Thread creation can fail due to resource limits (RLIMIT_NPROC),
    /// memory pressure, OS policy, or sandboxing. On failure:
    /// - The context pointer is properly deallocated (no leaks)
    /// - The closure is NOT invoked
    /// - The platform error code is preserved in the thrown error
    public struct Spawn: Sendable {
        @usableFromInline
        init() {}
    }

    /// Entry point for thread spawning.
    ///
    /// Usage: `let handle = try IO.Thread.spawn { ... }`
    public static var spawn: Spawn { Spawn() }
}

// MARK: - Spawn.Error

extension IO.Thread.Spawn {
    /// Error thrown when thread creation fails.
    ///
    /// Thread creation can fail due to:
    /// - Resource limits (RLIMIT_NPROC, memory pressure)
    /// - OS policy or sandboxing restrictions
    /// - Windows quota/policy limits
    ///
    /// The error preserves the platform-specific error code for diagnostics.
    public struct Error: Swift.Error, Sendable, Equatable, CustomStringConvertible {
        /// The platform where the error originated.
        public enum Platform: Sendable, Equatable {
            case windows
            case pthread
        }

        /// The platform where thread creation failed.
        public let platform: Platform

        /// The platform-specific error code.
        ///
        /// - On POSIX: The return value from `pthread_create` (e.g., EAGAIN, EPERM).
        /// - On Windows: The value from `GetLastError()`.
        public let code: Int

        /// Human-readable description of the failure.
        public var description: String {
            switch platform {
            case .windows:
                "CreateThread failed with error code \(code)"
            case .pthread:
                "pthread_create failed with error code \(code)"
            }
        }

        @usableFromInline
        init(platform: Platform, code: Int) {
            self.platform = platform
            self.code = code
        }

        #if os(Windows)
        @usableFromInline
        static func fromLastError() -> Self {
            Self(platform: .windows, code: Int(GetLastError()))
        }
        #else
        @usableFromInline
        static func fromPthreadResult(_ result: Int32) -> Self {
            Self(platform: .pthread, code: Int(result))
        }
        #endif
    }
}

// MARK: - callAsFunction (Throwing)

extension IO.Thread.Spawn {
    /// Spawns a dedicated OS thread.
    ///
    /// The closure is invoked exactly once on the spawned OS thread.
    /// This guarantee is essential for ownership-transfer patterns using
    /// `IO.Pointer.Retained`, where the closure takes ownership of a retained
    /// reference that must be released exactly once.
    ///
    /// - Parameter body: The work to run on the new thread. Executed exactly once.
    /// - Returns: An opaque handle to the thread.
    /// - Throws: `IO.Thread.Spawn.Error` if thread creation fails.
    public func callAsFunction(
        _ body: @escaping @Sendable () -> Void
    ) throws(Error) -> IO.Thread.Handle {
        #if os(Windows)
            let context = UnsafeMutablePointer<(@Sendable () -> Void)>.allocate(capacity: 1)
            context.initialize(to: body)

            let threadHandle = CreateThread(
                nil,
                0,
                { context in
                    guard let ctx = context else { return 0 }
                    let body = ctx.assumingMemoryBound(to: (@Sendable () -> Void).self)
                    // Ownership transfer: move() consumes the value, leaving memory uninitialized.
                    // We deallocate before running work() to minimize leak window.
                    let work = body.move()
                    body.deallocate()
                    work()
                    return 0
                },
                context,
                0,
                nil
            )

            guard let handle = threadHandle else {
                // Thread creation failed - clean up context to prevent leak.
                // deinitialize() required here because we haven't moved out of the memory.
                context.deinitialize(count: 1)
                context.deallocate()
                throw .fromLastError()
            }

            return IO.Thread.Handle(handle: handle)

        #elseif canImport(Darwin)
            var thread: pthread_t?
            let contextPtr = UnsafeMutablePointer<(@Sendable () -> Void)>.allocate(capacity: 1)
            contextPtr.initialize(to: body)

            let result = pthread_create(
                &thread,
                nil,
                { ctx in
                    // Darwin: ctx is non-optional UnsafeMutableRawPointer
                    let bodyPtr = ctx.assumingMemoryBound(to: (@Sendable () -> Void).self)
                    // Ownership transfer: move() consumes the value, leaving memory uninitialized.
                    // We deallocate before running work() to minimize leak window.
                    let work = bodyPtr.move()
                    bodyPtr.deallocate()
                    work()
                    return nil
                },
                contextPtr
            )

            guard result == 0, let thread else {
                // Thread creation failed - clean up context to prevent leak.
                // deinitialize() required here because we haven't moved out of the memory.
                contextPtr.deinitialize(count: 1)
                contextPtr.deallocate()
                throw .fromPthreadResult(result)
            }

            return IO.Thread.Handle(thread: thread)

        #else
            // Linux: pthread_t is non-optional
            var thread: pthread_t = 0
            let contextPtr = UnsafeMutablePointer<(@Sendable () -> Void)>.allocate(capacity: 1)
            contextPtr.initialize(to: body)

            let result = pthread_create(
                &thread,
                nil,
                { ctx in
                    guard let ctx else { return nil }
                    let bodyPtr = ctx.assumingMemoryBound(to: (@Sendable () -> Void).self)
                    // Ownership transfer: move() consumes the value, leaving memory uninitialized.
                    // We deallocate before running work() to minimize leak window.
                    let work = bodyPtr.move()
                    bodyPtr.deallocate()
                    work()
                    return nil
                },
                contextPtr
            )

            guard result == 0 else {
                // Thread creation failed - clean up context to prevent leak.
                // deinitialize() required here because we haven't moved out of the memory.
                contextPtr.deinitialize(count: 1)
                contextPtr.deallocate()
                throw .fromPthreadResult(result)
            }

            return IO.Thread.Handle(thread: thread)
        #endif
    }

    /// Spawns a dedicated OS thread with an explicit value.
    ///
    /// This variant accepts a `~Copyable` value that is passed to the closure,
    /// avoiding closure capture issues with move-only types. The value is
    /// transferred using `IO.Handoff.Cell`, the single audited mechanism for
    /// cross-boundary ownership transfer.
    ///
    /// - Parameters:
    ///   - value: A value to pass to the thread. Ownership is transferred.
    ///   - body: The work to run, receiving the value. Executed exactly once.
    /// - Returns: An opaque handle to the thread.
    /// - Throws: `IO.Thread.Spawn.Error` if thread creation fails.
    @inlinable
    public func callAsFunction<T: ~Copyable>(
        _ value: consuming T,
        _ body: @escaping @Sendable (consuming T) -> Void
    ) throws(Error) -> IO.Thread.Handle {
        // Use IO.Handoff for cross-boundary ownership transfer
        let cell = IO.Handoff.Cell(value)
        let token = cell.token()

        return try self {
            let v = token.take()
            body(v)
        }
    }
}
