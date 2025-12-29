//
//  IO.Blocking.Threads.Completion.Context.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 29/12/2025.
//

import Synchronization

extension IO.Blocking.Threads.Completion {
    /// Context for exactly-once completion resumption.
    ///
    /// This class enables the worker to resume the completion continuation directly,
    /// eliminating dictionary lookups. Uses atomic state to ensure exactly-once resumption
    /// between the completion path, cancellation path, and failure paths.
    ///
    /// ## State Machine
    /// ```
    /// ┌─────────┐
    /// │ pending │ ──tryComplete──> [completed] ──resume(returning: box)
    /// │   (0)   │ ──tryCancel────> [cancelled] ──resume(throwing: .cancellationRequested)
    /// │         │ ──tryFail──────> [failed]    ──resume(throwing: error)
    /// └─────────┘
    /// ```
    ///
    /// ## Memory Ordering
    /// - compareExchange uses `.acquiringAndReleasing` for full fence
    /// - This ensures the continuation read happens-before the resume
    /// - And the state transition is visible to all racing paths
    ///
    /// ## Exactly-Once Guarantee
    /// Only one of tryComplete/tryCancel/tryFail can succeed.
    /// All others return false and perform no action.
    final class Context: @unchecked Sendable {
        /// The continuation to resume with result or error.
        private let continuation: CheckedContinuation<IO.Blocking.Box.Pointer, any Error>

        /// Atomic state: 0 = pending, 1 = completed, 2 = cancelled, 3 = failed
        private let state: Atomic<UInt8>

        private static let pending: UInt8 = 0
        private static let completed: UInt8 = 1
        private static let cancelled: UInt8 = 2
        private static let failed: UInt8 = 3

        init(continuation: CheckedContinuation<IO.Blocking.Box.Pointer, any Error>) {
            self.continuation = continuation
            self.state = Atomic(Self.pending)
        }

        /// Try to complete with success. Returns true if this call resumed.
        ///
        /// Called by the worker after job execution.
        func tryComplete(with box: IO.Blocking.Box.Pointer) -> Bool {
            let (exchanged, _) = state.compareExchange(
                expected: Self.pending,
                desired: Self.completed,
                ordering: .acquiringAndReleasing
            )
            if exchanged {
                continuation.resume(returning: box)
                return true
            }
            return false
        }

        /// Try to cancel. Returns true if this call resumed.
        ///
        /// Called by the cancellation handler.
        func tryCancel() -> Bool {
            let (exchanged, _) = state.compareExchange(
                expected: Self.pending,
                desired: Self.cancelled,
                ordering: .acquiringAndReleasing
            )
            if exchanged {
                continuation.resume(throwing: IO.Blocking.Failure.cancellationRequested)
                return true
            }
            return false
        }

        /// Try to fail with an error. Returns true if this call resumed.
        ///
        /// Called when the operation cannot proceed:
        /// - `.shutdown`: Lane is shutting down
        /// - `.queueFull`: Queue is full and strategy is `.failFast`
        /// - `.overloaded`: Acceptance waiter queue is full
        /// - `.deadlineExceeded`: Acceptance deadline expired
        func tryFail(_ error: IO.Blocking.Failure) -> Bool {
            let (exchanged, _) = state.compareExchange(
                expected: Self.pending,
                desired: Self.failed,
                ordering: .acquiringAndReleasing
            )
            if exchanged {
                continuation.resume(throwing: error)
                return true
            }
            return false
        }

        /// Check if already resumed (for debugging).
        var isResumed: Bool {
            state.load(ordering: .acquiring) != Self.pending
        }

        /// Get the current state for debugging.
        var currentState: UInt8 {
            state.load(ordering: .acquiring)
        }
    }
}
