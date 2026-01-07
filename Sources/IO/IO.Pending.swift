//
//  IO.Pending.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 07/01/2026.
//

extension IO {
    /// Builder state awaiting close specification.
    ///
    /// ## Two-State Builder Pattern
    ///
    /// `Pending` represents the intermediate state where:
    /// - Lane is captured
    /// - Create closure is captured
    /// - Close closure is NOT yet specified
    ///
    /// This state has no `callAsFunction` - you cannot execute without
    /// specifying close behavior. This is enforced at compile time.
    ///
    /// ## Transition
    ///
    /// Call `.close(_:)` to transition to `Ready`:
    /// ```swift
    /// IO.open { Resource.make() }      // Returns Pending
    ///     .close { $0.teardown() }     // Returns Ready
    ///     { resource in ... }          // Executes via callAsFunction
    /// ```
    ///
    /// ## ~Copyable Resources
    ///
    /// Supports non-copyable resources via `Resource: ~Copyable`.
    /// The close closure takes `consuming Resource`.
    public struct Pending<
        L: Sendable,
        Resource: ~Copyable,
        CreateError: Swift.Error & Sendable
    >: Sendable {
        @usableFromInline
        let lane: L

        @usableFromInline
        let create: @Sendable () throws(CreateError) -> Resource

        @inlinable
        init(
            lane: L,
            create: @escaping @Sendable () throws(CreateError) -> Resource
        ) {
            self.lane = lane
            self.create = create
        }

        /// Specify the close behavior.
        ///
        /// Returns a `Ready` builder that can be executed via `callAsFunction`.
        ///
        /// - Parameter close: Closure to close the resource. Takes ownership.
        /// - Returns: A `Ready` builder.
        @inlinable
        public func close<CloseError: Swift.Error & Sendable>(
            _ close: @escaping @Sendable (consuming Resource) throws(CloseError) -> Void
        ) -> IO.Ready<L, Resource, CreateError, CloseError> {
            IO.Ready(lane: lane, create: create, close: close)
        }
    }
}

