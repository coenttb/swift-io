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
    /// ## Usage
    ///
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
    /// ## Error Handling
    ///
    /// Pool operations throw `IO.Pool.Failure<Body>`:
    ///
    /// ```swift
    /// do {
    ///     try await pool { conn in try conn.query() }
    /// } catch {
    ///     switch error {
    ///     case .pool(.exhausted): // retry later
    ///     case .pool(.timeout): // operation took too long
    ///     case .pool(.shutdown): // pool is closing
    ///     case .pool(.cancelled): // task was cancelled
    ///     case .body(let e): // user code failed
    ///     }
    /// }
    /// ```
    ///
    /// ## Swift Embedded Compatibility
    ///
    /// - No `any` types or protocol existentials
    /// - Fully typed throws throughout
    /// - `Never` elimination for non-throwing paths
    public actor Pool<Resource: ~Copyable & Sendable> {
        /// The lane for resource operations.
        @usableFromInline
        let lane: IO.Lane

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
        ///   - lane: The lane for resource operations.
        ///   - capacity: Maximum number of pooled resources.
        ///   - create: Factory that creates new resources.
        ///   - close: Destructor that closes resources.
        public init(
            on lane: IO.Lane = .shared,
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
    ///   - lane: The lane for resource operations.
    ///   - capacity: Maximum number of pooled resources.
    ///   - create: Factory that creates new resources.
    public init(
        on lane: IO.Lane = .shared,
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

