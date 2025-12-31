//
//  IO.Completion.Submission.Queue.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 31/12/2025.
//

import Synchronization

extension IO.Completion {
    /// Namespace for submission-related types.
    public enum Submission {}
}

extension IO.Completion.Submission {
    /// Thread-safe MPSC queue for actor → poll thread submission handoff.
    ///
    /// The `Queue` is the communication channel between the completion queue
    /// actor and the poll thread. The actor pushes operation storages, and
    /// the poll thread drains them for submission to the driver.
    ///
    /// ## Threading Model
    ///
    /// - **Producers**: Queue actor (multiple concurrent `submit()` calls)
    /// - **Consumer**: Poll thread (single `drain()` caller)
    ///
    /// This is an MPSC (multi-producer, single-consumer) queue.
    ///
    /// ## Usage
    ///
    /// ```swift
    /// // Actor side
    /// submissions.push(storage)
    /// wakeup.wake()
    ///
    /// // Poll thread side
    /// var buffer: [IO.Completion.Operation.Storage] = []
    /// let count = submissions.drain(into: &buffer)
    /// for storage in buffer {
    ///     try driver.submit(handle, storage: storage)
    /// }
    /// ```
    ///
    /// ## Thread Safety
    ///
    /// `@unchecked Sendable` because it provides internal synchronization via `Mutex`.
    public final class Queue: @unchecked Sendable {
        private let state: Mutex<State>

        private struct State {
            var storages: [IO.Completion.Operation.Storage] = []
        }

        /// Creates an empty submission queue.
        public init() {
            self.state = Mutex(State())
        }

        /// Pushes an operation storage for submission.
        ///
        /// Called from the queue actor. Thread-safe.
        ///
        /// - Parameter storage: The operation storage to submit.
        public func push(_ storage: IO.Completion.Operation.Storage) {
            state.withLock { state in
                state.storages.append(storage)
            }
        }

        /// Drains all pending storages into the buffer.
        ///
        /// Called from the poll thread. Thread-safe.
        ///
        /// - Parameter buffer: The buffer to drain into.
        /// - Returns: The number of storages drained.
        public func drain(into buffer: inout [IO.Completion.Operation.Storage]) -> Int {
            state.withLock { state in
                let count = state.storages.count
                buffer.append(contentsOf: state.storages)
                state.storages.removeAll(keepingCapacity: true)
                return count
            }
        }

        /// Returns the number of pending submissions.
        ///
        /// Mainly for testing and debugging.
        public var count: Int {
            state.withLock { state in
                state.storages.count
            }
        }
    }
}
