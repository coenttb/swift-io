//
//  IO.Blocking.Threads.Counter.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 24/12/2025.
//

import Synchronization

extension IO.Blocking.Threads {
    /// Thread-safe counter for generating unique IDs.
    ///
    /// Uses atomic operations for lock-free increment.
    public final class Counter: Sendable {
        private let value: Atomic<UInt64>

        public init(_ initial: UInt64 = 0) {
            self.value = Atomic(initial)
        }

        public func next() -> UInt64 {
            value.wrappingAdd(1, ordering: .relaxed).oldValue
        }
    }
}
