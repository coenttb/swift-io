//
//  IO.Executor.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 24/12/2025.
//

import Synchronization

extension IO {
    /// Namespace for executor types.
    ///
    /// Provides infrastructure for actor-based resource management:
    /// - `Pool`: Actor-based pool for managing resources with handles
    /// - `Shards`: Sharded collection of pools for concurrent access
    /// - `Handle`: Opaque resource references with scoped validity
    /// - `Slot`: Cross-await-boundary bridging for ~Copyable resources
    /// - `Transaction`: Exclusive access to pooled resources
    public enum Executor {}
}

extension IO.Executor {
    /// Thread-safe counter for generating unique scope IDs.
    final class Counter: Sendable {
        private let value: Atomic<UInt64>

        init(_ initial: UInt64 = 0) {
            self.value = Atomic(initial)
        }

        func next() -> UInt64 {
            value.wrappingAdd(1, ordering: .relaxed).oldValue
        }
    }

    /// Global counter for generating unique scope IDs across all Pool instances.
    static let scopeCounter = Counter()
}
