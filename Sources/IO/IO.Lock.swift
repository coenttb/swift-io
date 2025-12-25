//
//  IO.Lock.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 26/12/2025.
//

import Synchronization

extension IO {
    /// Internal mutual exclusion primitive for protecting mutable state.
    ///
    /// This is intentionally internal infrastructure. It centralizes the choice
    /// of synchronization primitive so it can be swapped in the future without
    /// changing call sites.
    ///
    /// ## Sendability
    /// This type is `@unchecked Sendable` because:
    /// - It is reference-semantic and designed to be shared across concurrency domains
    /// - All access to `State` is serialized through `withLock`
    /// - `State` values do not escape the closure
    /// - `State: Sendable` ensures values placed in the state don't smuggle
    ///   non-sendable references across concurrency domains
    ///
    /// This is the single audited choke point for `@unchecked Sendable` in the
    /// synchronization layer. Other types should depend on `_Lock` rather than
    /// marking themselves `@unchecked Sendable`.
    ///
    /// - Important: Callers must not allow references into `State` to escape the
    ///   `withLock` closure unless they remain properly synchronized.
    internal final class _Lock<State: Sendable>: @unchecked Sendable {
        private let mutex: Mutex<State>

        internal init(_ initialState: State) {
            self.mutex = Mutex(initialState)
        }

        /// Executes a closure with exclusive access to the protected state.
        ///
        /// The closure receives an `inout` reference to the state. No other
        /// thread can access the state until the closure returns.
        ///
        /// - Parameter body: A closure that operates on the protected state.
        /// - Returns: The value returned by the closure.
        @inline(__always)
        internal func withLock<T>(_ body: (inout State) -> T) -> T {
            mutex.withLock { body(&$0) }
        }
    }
}
