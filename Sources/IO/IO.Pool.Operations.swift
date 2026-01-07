//
//  IO.Pool.Operations.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 07/01/2026.
//

import Synchronization

// MARK: - Primary API

extension IO.Pool where Resource: ~Copyable {
    /// Execute a scoped operation with a pooled resource.
    ///
    /// This is the primary API for pool usage. A resource is acquired,
    /// the body is executed, and the resource is released automatically.
    ///
    /// ## Usage
    ///
    /// ```swift
    /// try await pool { connection in
    ///     connection.query(sql)
    /// }
    /// ```
    ///
    /// ## Error Handling
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
    /// - Parameter body: Closure that uses the resource.
    /// - Returns: The body's return value.
    @inlinable
    public func callAsFunction<T: Sendable, Body: Swift.Error & Sendable>(
        _ body: @Sendable (inout Resource) throws(Body) -> T
    ) async throws(Failure<Body>) -> T {
        // Check lifecycle
        guard isRunning else {
            throw .pool(.shutdown)
        }

        if Task.isCancelled {
            throw .pool(.cancelled)
        }

        // Create resource
        var resource: Resource
        do {
            resource = try create()
        } catch {
            throw .pool(error)
        }

        // Execute body
        var bodyError: Body? = nil
        var value: T? = nil
        do {
            value = try body(&resource)
        } catch {
            bodyError = error
        }

        // Close resource
        var closeError: Error? = nil
        do {
            try close(consume resource)
        } catch {
            closeError = error
        }

        // Compose result
        // Body error takes precedence over close error
        switch (bodyError, closeError) {
        case (nil, nil):
            return value!
        case (let body?, _):
            // Body error takes precedence
            throw .body(body)
        case (nil, let close?):
            throw .pool(close)
        }
    }
}

// MARK: - Long-Lived Checkout

extension IO.Pool where Resource: ~Copyable {
    /// Acquire a resource ID for long-lived checkout.
    ///
    /// The returned ID must be released via `pool.release(id)`.
    ///
    /// ## Usage
    ///
    /// ```swift
    /// let id = try await pool.acquire()
    /// try await pool.with(id) { connection in
    ///     connection.query(sql)
    /// }
    /// try await pool.release(id)
    /// ```
    ///
    /// - Returns: A unique resource identifier.
    /// - Throws: `IO.Pool.Error` on failure.
    public func acquire() async throws(Error) -> ID {
        guard isRunning else {
            throw .shutdown
        }

        if Task.isCancelled {
            throw .cancelled
        }

        // For now, simple implementation: create resource on demand
        // A full implementation would have a resource registry
        let id = ID(scope: scope)

        return id
    }

    /// Execute a body with a checked-out resource.
    ///
    /// The resource identified by `id` must have been acquired via
    /// `pool.acquire()` and not yet released.
    ///
    /// - Parameters:
    ///   - id: The resource ID from `acquire()`.
    ///   - body: Closure that uses the resource.
    /// - Returns: The body's return value.
    @inlinable
    public func with<T: Sendable, Body: Swift.Error & Sendable>(
        _ id: ID,
        _ body: @Sendable (inout Resource) throws(Body) -> T
    ) async throws(Failure<Body>) -> T {
        guard isRunning else {
            throw .pool(.shutdown)
        }

        guard id.scope == scope else {
            throw .pool(.scopeMismatch)
        }

        if Task.isCancelled {
            throw .pool(.cancelled)
        }

        // Create resource
        var resource: Resource
        do {
            resource = try create()
        } catch {
            throw .pool(error)
        }

        // Execute body directly (simplified implementation)
        var bodyError: Body? = nil
        var value: T? = nil
        do {
            value = try body(&resource)
        } catch {
            bodyError = error
        }

        // Close resource
        var closeError: Error? = nil
        do {
            try close(consume resource)
        } catch {
            closeError = error
        }

        // Compose result - body error takes precedence
        switch (bodyError, closeError) {
        case (nil, nil):
            return value!
        case (let body?, _):
            throw .body(body)
        case (nil, let close?):
            throw .pool(close)
        }
    }

    /// Release a checked-out resource.
    ///
    /// After release, the ID is no longer valid.
    ///
    /// - Parameter id: The resource ID from `acquire()`.
    /// - Throws: `IO.Pool.Error` on failure.
    public func release(_ id: ID) async throws(Error) {
        guard id.scope == scope else {
            throw .scopeMismatch
        }

        // For this simplified implementation, release is a no-op
        // A full implementation would return the resource to the pool
    }
}

// MARK: - Scoped Acquire

extension IO.Pool where Resource: ~Copyable {
    /// Acquire with automatic release scope.
    ///
    /// The ID is automatically released when the body completes.
    ///
    /// - Parameter body: Async closure that uses the ID.
    /// - Returns: The body's return value.
    @usableFromInline
    func acquireScoped<T: Sendable, Body: Swift.Error & Sendable>(
        _ body: @Sendable (ID) async throws(Body) -> T
    ) async throws(Failure<Body>) -> T {
        // Acquire
        let id: ID
        do {
            id = try await acquire()
        } catch {
            throw .pool(error)
        }

        // Execute body
        var bodyError: Body? = nil
        var result: T? = nil
        do {
            result = try await body(id)
        } catch {
            bodyError = error
        }

        // Release (best effort)
        var releaseError: Error? = nil
        do {
            try await release(id)
        } catch {
            releaseError = error
        }

        // Compose result - body error takes precedence
        switch (bodyError, releaseError) {
        case (nil, nil):
            return result!
        case (let body?, _):
            throw .body(body)
        case (nil, let release?):
            throw .pool(release)
        }
    }
}

// MARK: - Shutdown

extension IO.Pool where Resource: ~Copyable {
    /// Shut down the pool.
    ///
    /// After shutdown, no new operations are accepted.
    public func shutdown() async {
        isRunning = false
        await lane.shutdown()
    }
}
