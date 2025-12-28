//
//  IO.Handle.Waiter.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 28/12/2025.
//

import Synchronization

extension IO.Handle {
    /// Thread-safe waiter cell with synchronous cancellation intent.
    ///
    /// ## Cancellation Model: "Synchronous state flip, actor drains on next touch"
    ///
    /// - `cancel()` flips the cancelled bit synchronously from any thread (onCancel handler)
    /// - `cancel()` does NOT resume the continuation
    /// - The actor calls `takeForResume()` during drain to get the continuation
    /// - The actor resumes the continuation on its executor
    ///
    /// This ensures:
    /// - Single funnel for continuation resumption (actor executor only)
    /// - No "resume under lock" hazards
    /// - No continuation resumed from arbitrary cancellation threads
    ///
    /// ## State Machine
    /// ```
    /// armed ──cancel()──▶ cancelled
    ///   │                    │
    ///   │                    │
    ///   ▼                    ▼
    /// takeForResume()    takeForResume()
    ///   │                    │
    ///   ▼                    ▼
    /// drained            drained
    /// ```
    ///
    /// ## Thread Safety
    /// `@unchecked Sendable` because it provides internal synchronization via `Atomic`.
    public final class Waiter: @unchecked Sendable {
        /// Internal state representation.
        ///
        /// Uses bit patterns for atomic operations:
        /// - Bit 0: cancelled flag
        /// - Bit 1: drained flag (continuation taken)
        private struct State: RawRepresentable, AtomicRepresentable, Equatable {
            var rawValue: UInt8

            static let armed = State(rawValue: 0b00)
            static let cancelled = State(rawValue: 0b01)
            static let drained = State(rawValue: 0b10)
            static let cancelledAndDrained = State(rawValue: 0b11)

            var isCancelled: Bool { rawValue & 0b01 != 0 }
            var isDrained: Bool { rawValue & 0b10 != 0 }

            init(rawValue: UInt8) {
                self.rawValue = rawValue
            }
        }

        /// Atomic state for lock-free cancellation.
        private let state = Atomic<State>(.armed)

        /// The continuation. Only accessed after state transition under atomic guard.
        /// Set once during init, cleared once during takeForResume.
        private var continuation: CheckedContinuation<Void, Never>?

        /// Unique token for identification in the waiter queue.
        public let token: UInt64

        /// Creates an armed waiter ready to be enqueued.
        ///
        /// - Parameters:
        ///   - token: Unique identifier for this waiter.
        ///   - continuation: The continuation to resume when drained.
        public init(token: UInt64, continuation: CheckedContinuation<Void, Never>) {
            self.token = token
            self.continuation = continuation
        }

        /// Mark this waiter as cancelled. Synchronous, lock-free.
        ///
        /// This method can be called from any thread, including `onCancel` handlers.
        /// It does NOT resume the continuation - that happens during actor drain.
        ///
        /// - Returns: `true` if successfully transitioned to cancelled state.
        ///   `false` if already cancelled or already drained.
        @discardableResult
        public func cancel() -> Bool {
            // Try: armed -> cancelled
            let (exchanged, original) = state.compareExchange(
                expected: .armed,
                desired: .cancelled,
                ordering: .acquiringAndReleasing
            )
            return exchanged
        }

        /// Check if this waiter was cancelled.
        ///
        /// Safe to call from any thread.
        public var wasCancelled: Bool {
            state.load(ordering: .acquiring).isCancelled
        }

        /// Check if this waiter has been drained (continuation taken).
        ///
        /// Safe to call from any thread.
        public var isDrained: Bool {
            state.load(ordering: .acquiring).isDrained
        }

        /// Take the continuation for resumption. Actor-only operation.
        ///
        /// This method transitions the waiter to drained state and returns the
        /// continuation. The actor must resume the returned continuation.
        ///
        /// - Returns: The continuation if available, along with cancellation status.
        ///   Returns `nil` if already drained.
        public func takeForResume() -> (continuation: CheckedContinuation<Void, Never>, wasCancelled: Bool)? {
            let currentState = state.load(ordering: .acquiring)

            // Already drained - nothing to do
            if currentState.isDrained {
                return nil
            }

            // Transition to drained state
            let newState: State = currentState.isCancelled ? .cancelledAndDrained : .drained
            let (exchanged, _) = state.compareExchange(
                expected: currentState,
                desired: newState,
                ordering: .acquiringAndReleasing
            )

            guard exchanged else {
                // Race with cancel() - retry
                return takeForResume()
            }

            // Take the continuation (only one caller can reach here per waiter)
            guard let c = continuation else {
                preconditionFailure("Waiter drained but continuation was nil")
            }
            continuation = nil

            return (c, currentState.isCancelled)
        }
    }
}
