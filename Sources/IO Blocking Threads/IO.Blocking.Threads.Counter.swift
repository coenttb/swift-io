//
//  IO.Blocking.Threads.Counter.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 24/12/2025.
//

extension IO.Blocking.Threads {
    /// Thread-safe counter for generating unique IDs.
    ///
    /// Uses the Lock from this module to ensure all synchronization primitives
    /// are consolidated.
    public final class Counter: @unchecked Sendable {
        private let lock = Lock()
        private var value: UInt64 = 0

        public init() {}

        public func next() -> UInt64 {
            lock.withLock {
                let result = value
                value += 1
                return result
            }
        }
    }
}
