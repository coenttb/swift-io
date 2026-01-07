//
//  IO.Scope.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 07/01/2026.
//

extension IO {
    /// Namespace for scoped resource lifecycle types.
    ///
    /// ## Overview
    ///
    /// `IO.Scope` provides structured resource management with typed error handling.
    /// Resources are acquired, used within a scope, and automatically released.
    ///
    /// ## Types
    ///
    /// - `Failure<C, B, Cl>`: Three-generic error for create/body/close failures
    /// - `Pending<L, R, C>`: Builder awaiting close specification
    /// - `Ready<L, R, C, Cl>`: Builder ready for execution
    ///
    /// ## Usage
    ///
    /// ```swift
    /// // Via lane.open builder
    /// try await lane.open { Resource.make() }
    ///     .close { $0.teardown() }
    ///     { resource in
    ///         resource.work()
    ///     }
    /// ```
    public enum Scope {}
}
