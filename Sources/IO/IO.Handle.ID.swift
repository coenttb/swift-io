//
//  IO.Handle.ID.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 24/12/2025.
//

extension IO.Handle {
    /// A unique identifier for a registered handle.
    ///
    /// IDs are:
    /// - Scoped to a specific executor instance (prevents cross-executor misuse)
    /// - Never reused within an executor's lifetime
    /// - Sendable and Hashable for use as dictionary keys
    ///
    /// ## Shard Affinity
    ///
    /// When using `IO.Executor.Shards`, the `shard` field indicates which shard
    /// owns this handle. This enables O(1) routing without scope arithmetic.
    public struct ID: Hashable, Sendable {
        /// The unique identifier within the executor (or shard).
        public let raw: UInt64
        /// The scope identifier (unique per executor/pool instance).
        public let scope: UInt64
        /// The shard index for routing in sharded pools.
        ///
        /// For non-sharded pools, this is always 0.
        public let shard: UInt16

        public init(raw: UInt64, scope: UInt64, shard: UInt16 = 0) {
            self.raw = raw
            self.scope = scope
            self.shard = shard
        }
    }
}
