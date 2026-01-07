//
//  IO.Pool.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 07/01/2026.
//

extension IO {
    /// Resource pool with typed error handling.
    ///
    /// ## Overview
    ///
    /// `IO.Pool` manages a fixed-capacity pool of resources. Resources are
    /// created lazily and reused across operations. The pool provides both
    /// scoped access (via `callAsFunction`) and explicit checkout/release.
    ///
    /// ## Usage Patterns
    ///
    /// ### Simple Use (callAsFunction)
    /// ```swift
    /// let pool = IO.Pool(on: lane, capacity: 16) {
    ///     try Connection.open(config)
    /// } close: {
    ///     try $0.close()
    /// }
    ///
    /// try await pool { connection in
    ///     connection.query(sql)
    /// }
    /// ```
    ///
    /// ### Long-Lived Checkout
    /// ```swift
    /// let id = try await pool.acquire()
    /// try await pool.with(id) { connection in
    ///     connection.query(sql)
    /// }
    /// try await pool.release(id)
    /// ```
    ///
    /// ### Auto-Release Scope
    /// ```swift
    /// try await pool.acquire.scoped { id in
    ///     try await pool.with(id) { conn in ... }
    /// }
    /// ```
    ///
    /// ## Error Handling
    ///
    /// Pool operations use composed typed throws:
    /// - `IO.Pool.Error`: Infrastructure errors (shutdown, exhausted, etc.)
    /// - `IO.Pool.Scoped.Failure<Body>`: Scoped operation errors
    /// - `IO.Lifecycle.Error<...>`: Lifecycle wrapper for full error type
    ///
    /// ## Swift Embedded Compatibility
    ///
    /// - No `any` types or protocol existentials
    /// - Fully typed throws throughout
    /// - `Never` elimination for non-throwing paths
    public actor Pool<Resource: ~Copyable & Sendable> {
        /// The blocking lane for resource operations.
        @usableFromInline
        let lane: IO.Blocking.Lane

        /// Maximum number of resources in the pool.
        @usableFromInline
        let capacity: Capacity

        /// Factory for creating new resources.
        @usableFromInline
        let create: @Sendable () throws(Error) -> Resource

        /// Destructor for closing resources.
        @usableFromInline
        let close: @Sendable (consuming Resource) throws(Error) -> Void

        /// Pool scope identifier for ID validation.
        @usableFromInline
        let scope: Scope

        /// Whether the pool is accepting new operations.
        @usableFromInline
        var isRunning: Bool

        /// Creates a new resource pool.
        ///
        /// - Parameters:
        ///   - lane: The blocking lane for resource operations.
        ///   - capacity: Maximum number of pooled resources.
        ///   - create: Factory that creates new resources.
        ///   - close: Destructor that closes resources.
        public init(
            on lane: IO.Blocking.Lane,
            capacity: Capacity,
            _ create: @Sendable @escaping () throws(Error) -> Resource,
            close: @Sendable @escaping (consuming Resource) throws(Error) -> Void
        ) {
            self.lane = lane
            self.capacity = capacity
            self.create = create
            self.close = close
            self.scope = Scope()
            self.isRunning = true
        }
    }
}

// MARK: - IO.Closable Convenience

extension IO.Pool where Resource: IO.Closable, Resource.CloseError == Never {
    /// Creates a pool for resources with infallible close.
    ///
    /// The resource's `close()` method is called automatically when
    /// the resource is removed from the pool.
    ///
    /// - Parameters:
    ///   - lane: The blocking lane for resource operations.
    ///   - capacity: Maximum number of pooled resources.
    ///   - create: Factory that creates new resources.
    public init(
        on lane: IO.Blocking.Lane,
        capacity: Capacity,
        _ create: @Sendable @escaping () throws(Error) -> Resource
    ) {
        self.init(
            on: lane,
            capacity: capacity,
            create,
            close: { resource in resource.close() }
        )
    }
}

// MARK: - Shared Lane Convenience

extension IO.Pool where Resource: ~Copyable {
    /// Creates a pool on the shared lane with custom close.
    ///
    /// Uses `IO.Blocking.Lane.shared` for resource operations.
    ///
    /// ## Usage
    /// ```swift
    /// let pool = IO.Pool(capacity: 16) {
    ///     try Connection.open(config)
    /// } close: {
    ///     try $0.close()
    /// }
    ///
    /// try await pool { connection in
    ///     connection.query(sql)
    /// }
    /// ```
    ///
    /// - Parameters:
    ///   - capacity: Maximum number of pooled resources.
    ///   - create: Factory that creates new resources.
    ///   - close: Destructor that closes resources.
    public init(
        capacity: Capacity,
        _ create: @Sendable @escaping () throws(Error) -> Resource,
        close: @Sendable @escaping (consuming Resource) throws(Error) -> Void
    ) {
        self.init(on: IO.Blocking.Lane.shared, capacity: capacity, create, close: close)
    }
}

extension IO.Pool where Resource: IO.Closable, Resource.CloseError == Never {
    /// Creates a pool on the shared lane with inferred close.
    ///
    /// Uses `IO.Blocking.Lane.shared` for resource operations.
    /// The resource's `close()` method is called automatically.
    ///
    /// ## Usage
    /// ```swift
    /// let pool = IO.Pool(capacity: 16) {
    ///     try Connection.open(config)
    /// }
    ///
    /// try await pool { connection in
    ///     connection.query(sql)
    /// }
    /// ```
    ///
    /// - Parameters:
    ///   - capacity: Maximum number of pooled resources.
    ///   - create: Factory that creates new resources.
    public init(
        capacity: Capacity,
        _ create: @Sendable @escaping () throws(Error) -> Resource
    ) {
        self.init(on: IO.Blocking.Lane.shared, capacity: capacity, create)
    }
}
