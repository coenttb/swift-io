//
//  IO.Pool.Scoped.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 07/01/2026.
//

extension IO.Pool where Resource: ~Copyable {
    /// Namespace for scoped pool operation types.
    ///
    /// ## Overview
    ///
    /// Types in this namespace relate to scoped operations that acquire
    /// a resource, use it, and release it automatically.
    ///
    /// ## Types
    ///
    /// - `Failure<Body>`: Error type for scoped operations
    public enum Scoped {}
}
