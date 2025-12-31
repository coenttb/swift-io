//
//  IO.Event.Registration.Queue.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 28/12/2025.
//

import Synchronization

extension IO.Event.Registration {
    /// Thread-safe queue for registration requests from selector to poll thread.
    ///
    /// The `Queue` allows the selector actor to enqueue registration requests
    /// that the poll thread processes between poll cycles.
    ///
    /// ## Thread Safety
    /// `@unchecked Sendable` because it provides internal synchronization via `Mutex`.
    ///
    /// ## Pattern
    /// - Selector enqueues requests via `enqueue(_:)`
    /// - Poll thread dequeues via `dequeue()`
    /// - Shutdown drains remaining requests via `dequeueAll()`
    public final class Queue: @unchecked Sendable {
        let state: Mutex<State>

        struct State {
            var requests: [Request] = []
            var isShutdown: Bool = false
        }

        /// Creates a new registration queue.
        public init() {
            self.state = Mutex(State())
        }
    }
}
