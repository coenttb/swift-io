//
//  IO.Pool.Scope.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 07/01/2026.
//

import Synchronization

/// Global counter for pool scope generation.
private let _poolScopeCounter = Atomic<UInt64>(0)

extension IO.Pool where Resource: ~Copyable {
    /// Unique identifier for a pool instance.
    ///
    /// ## Design
    ///
    /// Each pool has a unique scope. IDs include the scope to prevent
    /// using an ID from one pool with another pool (`.scopeMismatch`).
    ///
    /// ## Generation
    ///
    /// Scopes are generated using an atomic counter, ensuring uniqueness
    /// across the process lifetime.
    public struct Scope: Hashable, Sendable {
        /// The raw scope identifier.
        let rawValue: UInt64

        /// Creates a new unique scope.
        init() {
            self.rawValue = _poolScopeCounter.wrappingAdd(1, ordering: .relaxed).oldValue
        }
    }
}

// MARK: - CustomStringConvertible

extension IO.Pool.Scope: CustomStringConvertible {
    public var description: String {
        "Scope(\(rawValue))"
    }
}
