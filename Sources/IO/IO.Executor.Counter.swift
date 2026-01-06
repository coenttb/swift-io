//
//  File.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 05/01/2026.
//

import Synchronization

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
