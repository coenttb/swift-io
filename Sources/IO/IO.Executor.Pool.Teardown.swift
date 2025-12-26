//
//  IO.Executor.Pool.Teardown.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 25/12/2025.
//

extension IO.Executor {
    /// Teardown strategy for deterministic resource cleanup.
    ///
    /// When a resource is removed from a pool (via `destroy()`, `shutdown()`,
    /// or check-in after destruction), the pool invokes the teardown to perform
    /// resource-specific cleanup.
    ///
    /// ## Slot-Based Design
    /// Teardown receives a `Slot.Address` (which is Sendable) rather than
    /// the resource directly. This allows teardown to run blocking operations
    /// on the lane without violating ~Copyable ownership rules.
    ///
    /// ## Contract
    /// The teardown closure **MUST** consume the resource at `address` using
    /// `Slot.Container.consume(at:)` or `Slot.Container.take(at:)`.
    /// Do NOT use `withResource(at:)` which only borrows.
    /// The pool deallocates the slot's raw memory after teardown returns -
    /// if the resource wasn't consumed, it will leak.
    ///
    /// ## Common Patterns
    /// ```swift
    /// // Just drop the resource (no cleanup needed)
    /// let pool = Pool<MyResource>(lane: lane, teardown: .drop())
    ///
    /// // Close on the lane (for file handles, sockets, etc.)
    /// let pool = Pool<File.Handle>(lane: lane, teardown: .onLane(lane) { handle in
    ///     try? handle.close()
    /// })
    /// ```
    public struct Teardown<Resource: ~Copyable>: Sendable {
        /// The underlying closure that performs teardown.
        let closure: @Sendable (_ address: IO.Executor.Slot.Address) async -> Void

        /// Creates a teardown with the given closure.
        ///
        /// - Parameter closure: The teardown closure. Must consume the resource at address.
        init(_ closure: @escaping @Sendable (_ address: IO.Executor.Slot.Address) async -> Void) {
            self.closure = closure
        }

        /// Invokes the teardown.
        func callAsFunction(_ address: IO.Executor.Slot.Address) async {
            await closure(address)
        }

        // MARK: - Static Factories

        /// Drops the resource without any cleanup.
        ///
        /// Use this when the resource has no cleanup requirements or when
        /// cleanup is handled elsewhere (e.g., deinit).
        ///
        /// This is the default teardown if none is specified.
        public static func drop() -> Teardown {
            Teardown { address in
                _ = IO.Executor.Slot.Container<Resource>.take(at: address.pointer)
            }
        }

        /// Consumes the resource and runs cleanup on the given lane.
        ///
        /// Use this for resources that require blocking cleanup operations
        /// (closing file descriptors, network sockets, database connections, etc.).
        ///
        /// ## Example
        /// ```swift
        /// let pool = Pool<File.Handle>(
        ///     lane: lane,
        ///     teardown: .onLane(lane) { handle in
        ///         try? handle.close()
        ///     }
        /// )
        /// ```
        ///
        /// - Parameters:
        ///   - lane: The lane to run the cleanup operation on.
        ///   - cleanup: Closure that consumes the resource and performs cleanup.
        /// - Returns: A teardown that runs cleanup on the lane.
        public static func onLane(
            _ lane: IO.Blocking.Lane,
            cleanup: @escaping @Sendable (consuming Resource) -> Void
        ) -> Teardown {
            Teardown { address in
                _ = try? await lane.run(deadline: nil) {
                    IO.Executor.Slot.Container<Resource>.consume(at: address.pointer) { resource in
                        cleanup(resource)
                    }
                }
            }
        }

        /// Consumes the resource and runs throwing cleanup on the given lane.
        ///
        /// Errors from cleanup are silently ignored. Use this when cleanup
        /// is best-effort (e.g., closing a file handle that may already be closed).
        ///
        /// - Parameters:
        ///   - lane: The lane to run the cleanup operation on.
        ///   - cleanup: Throwing closure that consumes the resource and performs cleanup.
        /// - Returns: A teardown that runs cleanup on the lane, ignoring errors.
        public static func onLane(
            _ lane: IO.Blocking.Lane,
            cleanup: @escaping @Sendable (consuming Resource) throws -> Void
        ) -> Teardown {
            Teardown { address in
                _ = try? await lane.run(deadline: nil) {
                    IO.Executor.Slot.Container<Resource>.consume(at: address.pointer) { resource in
                        try? cleanup(resource)
                    }
                }
            }
        }
    }
}
