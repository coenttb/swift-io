//
//  IO.Pool.ID.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 07/01/2026.
//

import Synchronization

/// Global counter for pool ID generation.
private let _poolIDCounter = Atomic<UInt64>(0)

extension IO.Pool where Resource: ~Copyable {
    /// Identifier for a checked-out resource.
    ///
    /// ## Design
    ///
    /// IDs are returned from `pool.acquire()` and used with `pool.with(id:)`
    /// and `pool.release(id:)` for long-lived checkouts.
    ///
    /// ## Validation
    ///
    /// IDs include the pool scope. Using an ID with the wrong pool
    /// throws `.scopeMismatch`. Using an already-released ID throws
    /// `.invalidID`.
    ///
    /// ## Uniqueness
    ///
    /// IDs are unique within a scope. The combination of scope + rawValue
    /// is unique across all pools in the process.
    public struct ID: Hashable, Sendable {
        /// The pool scope this ID belongs to.
        public let scope: Scope

        /// The raw identifier within the scope.
        let rawValue: UInt64

        /// Creates a new ID in the given scope.
        init(scope: Scope) {
            self.scope = scope
            self.rawValue = _poolIDCounter.wrappingAdd(1, ordering: .relaxed).oldValue
        }
    }
}

// MARK: - CustomStringConvertible

extension IO.Pool.ID: CustomStringConvertible {
    public var description: String {
        "ID(\(scope.rawValue):\(rawValue))"
    }
}
