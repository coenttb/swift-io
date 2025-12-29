//
//  IO.Executor.Teardown.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 29/12/2025.
//

extension IO.Executor {
    /// Teardown policy for resource cleanup during pool shutdown or registration failure.
    ///
    /// ## Design
    /// Teardown describes *what* to do with a resource; the pool decides *where/when*.
    /// The pool executes teardown actions on its lane, ensuring blocking cleanup
    /// (close, fsync, flush) runs in the correct execution domain.
    ///
    /// ## Guarantees
    /// - Teardown is executed exactly once per registered resource during shutdown
    /// - Teardown is infallible (best-effort cleanup, errors swallowed)
    /// - No ordering guarantee between resources
    ///
    /// ## Extensibility
    /// Downstream libraries extend `Teardown` with domain-specific statics:
    /// ```swift
    /// extension IO.Executor.Teardown where Resource == File.Handle {
    ///     public static var close: Self {
    ///         .init { handle in try? handle.close() }
    ///     }
    /// }
    /// ```
    public struct Teardown<Resource: ~Copyable & Sendable>: Sendable {
        /// The teardown action to run on a resource.
        ///
        /// - Parameter resource: The resource to clean up (ownership transferred).
        public typealias Action = @Sendable (_ resource: consuming Resource) -> Void

        /// The teardown action, or nil for no-op.
        @usableFromInline
        internal let action: Action?

        /// Creates a teardown policy with the given action.
        ///
        /// - Parameter action: The cleanup action, or nil for no-op.
        @inlinable
        public init(_ action: Action?) {
            self.action = action
        }
    }
}

// MARK: - Standard Policies

extension IO.Executor.Teardown where Resource: ~Copyable {
    /// No cleanup action. Resources are dropped without explicit teardown.
    @inlinable
    public static var none: Self { .init(nil) }

    /// Drop resource without explicit cleanup (relies on deinit).
    ///
    /// Semantically equivalent to `.none`. Use when you want to explicitly
    /// document that cleanup is via deinit, not a teardown action.
    @inlinable
    public static var drop: Self { .none }
}

