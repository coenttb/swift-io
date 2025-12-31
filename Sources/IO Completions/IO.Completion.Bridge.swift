//
//  IO.Completion.Bridge.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 31/12/2025.
//

import Synchronization

extension IO.Completion {
    /// Thread-safe bridge for poll thread → queue actor event handoff.
    ///
    /// The `Bridge` solves the fundamental problem of transferring
    /// completion events from a synchronous OS thread (poll thread)
    /// to an async actor (queue) without blocking the poll thread.
    ///
    /// ## Pattern
    ///
    /// - Poll thread calls `push(_:)` (synchronous, never blocks indefinitely)
    /// - Queue actor calls `next()` (async, suspends until events available)
    ///
    /// ## Thread Safety
    ///
    /// `@unchecked Sendable` because it provides internal synchronization via `Mutex`.
    ///
    /// ## Shutdown
    ///
    /// Call `shutdown()` to signal the bridge is closing. Any pending `next()`
    /// call will return `nil`, and future `next()` calls return `nil` immediately.
    public final class Bridge: @unchecked Sendable {
        let state: Mutex<State>

        struct State {
            var batches: [[Event]] = []
            var continuation: CheckedContinuation<[Event]?, Never>?
            var isShutdown: Bool = false
        }

        /// Creates a new completion event bridge.
        public init() {
            self.state = Mutex(State())
        }

        /// Pushes a batch of events from the poll thread.
        ///
        /// This method never blocks. If there's a waiting continuation,
        /// it's resumed immediately. Otherwise, events are queued.
        ///
        /// - Parameter events: The events to deliver.
        public func push(_ events: [Event]) {
            guard !events.isEmpty else { return }

            let continuation: CheckedContinuation<[Event]?, Never>? = state.withLock { state in
                if state.isShutdown {
                    return nil
                }

                if let cont = state.continuation {
                    state.continuation = nil
                    return cont
                } else {
                    state.batches.append(events)
                    return nil
                }
            }

            continuation?.resume(returning: events)
        }

        /// Waits for the next batch of events.
        ///
        /// This method suspends until events are available or shutdown occurs.
        ///
        /// - Returns: A batch of events, or `nil` if the bridge is shut down.
        public func next() async -> [Event]? {
            await withCheckedContinuation { continuation in
                let result: [Event]? = state.withLock { state in
                    if state.isShutdown {
                        return [Event]()  // Return empty to signal shutdown
                    }

                    if let batch = state.batches.first {
                        state.batches.removeFirst()
                        return batch
                    }

                    // Park the continuation
                    state.continuation = continuation
                    return nil
                }

                if let events = result {
                    continuation.resume(returning: events.isEmpty ? nil : events)
                }
                // Otherwise continuation is parked
            }
        }

        /// Signals that the bridge is shutting down.
        ///
        /// Any pending `next()` call will return `nil`.
        public func shutdown() {
            let continuation: CheckedContinuation<[Event]?, Never>? = state.withLock { state in
                state.isShutdown = true
                let cont = state.continuation
                state.continuation = nil
                return cont
            }

            continuation?.resume(returning: nil)
        }
    }
}
