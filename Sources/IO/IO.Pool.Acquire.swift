//
//  IO.Pool.Acquire.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 07/01/2026.
//

extension IO.Pool where Resource: ~Copyable & Sendable {
    /// Nested accessor for scoped acquire operations.
    ///
    /// Use:
    /// - `try await pool.acquire()` for direct acquire (method on Pool)
    /// - `try await pool.checkout.scoped { ... }` for auto-release scope
    ///
    /// ## Design
    ///
    /// The accessor provides trailing-closure APIs only. Direct acquire is
    /// a method on `IO.Pool` to avoid IRGen issues with `callAsFunction`
    /// on nested types under ~Copyable generics.
    public var checkout: Checkout {
        Checkout(pool: self)
    }

    /// Namespace for scoped checkout operations.
    ///
    /// ## Usage
    ///
    /// ```swift
    /// // Scoped acquire with auto-release
    /// try await pool.checkout.scoped { id in
    ///     try await pool.with(id) { resource in ... }
    /// }
    /// ```
    public struct Checkout: Sendable {
        /// Reference to the pool.
        @usableFromInline
        let pool: IO.Pool<Resource>

        @usableFromInline
        init(pool: IO.Pool<Resource>) {
            self.pool = pool
        }

        /// Acquire with automatic release scope.
        ///
        /// The ID is automatically released when the body completes,
        /// even if it throws.
        ///
        /// ## Usage
        ///
        /// ```swift
        /// try await pool.checkout.scoped { id in
        ///     try await pool.with(id) { connection in
        ///         connection.query(sql)
        ///     }
        /// }
        /// // ID automatically released
        /// ```
        ///
        /// - Parameter body: Async closure that uses the ID.
        /// - Returns: The body's return value.
        @inlinable
        public func scoped<T: Sendable, Body: Swift.Error & Sendable>(
            _ body: @Sendable (ID) async throws(Body) -> T
        ) async throws(Failure<Body>) -> T {
            try await pool.acquireScoped(body)
        }
    }
}
