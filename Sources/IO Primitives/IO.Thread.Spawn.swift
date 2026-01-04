//
//  IO.Thread.Spawn.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 30/12/2025.
//

public import Kernel

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
    /// Wraps `Kernel.Thread.Error` with additional context.
    public struct Error: Swift.Error, Sendable, Equatable, CustomStringConvertible {
        /// The underlying kernel error.
        public let kernelError: Kernel.Thread.Error

        /// Human-readable description of the failure.
        public var description: String {
            kernelError.description
        }

        @usableFromInline
        init(_ kernelError: Kernel.Thread.Error) {
            self.kernelError = kernelError
        }
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
    @inlinable
    public func callAsFunction(
        _ body: @escaping @Sendable () -> Void
    ) throws(Error) -> IO.Thread.Handle {
        do {
            let kernelHandle = try Kernel.Thread.create(body)
            return IO.Thread.Handle(kernelHandle)
        } catch {
            throw Error(error)
        }
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
