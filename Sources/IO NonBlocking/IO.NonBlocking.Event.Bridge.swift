//
//  IO.NonBlocking.Event.Bridge.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 28/12/2025.
//

import Synchronization

extension IO.NonBlocking.Event {
    /// Thread-safe bridge for poll thread → selector actor event handoff.
    ///
    /// The `Bridge` solves the fundamental problem of transferring
    /// events from a synchronous OS thread (poll thread) to an async actor
    /// (selector) without blocking the poll thread or losing events.
    ///
    /// ## Pattern
    /// - Poll thread calls `push(_:)` (synchronous, never blocks indefinitely)
    /// - Selector actor calls `next()` (async, suspends until events available)
    ///
    /// ## Thread Safety
    /// `@unchecked Sendable` because it provides internal synchronization via `Mutex`.
    ///
    /// ## Shutdown
    /// Call `shutdown()` to signal the bridge is closing. Any pending `next()`
    /// call will return `nil`, and future `next()` calls return `nil` immediately.
    public final class Bridge: @unchecked Sendable {
        let state: Mutex<State>

        struct State {
            var batches: [[IO.NonBlocking.Event]] = []
            var continuation: CheckedContinuation<[IO.NonBlocking.Event]?, Never>?
            var isShutdown: Bool = false
        }

        /// Creates a new event bridge.
        public init() {
            self.state = Mutex(State())
        }
    }
}
