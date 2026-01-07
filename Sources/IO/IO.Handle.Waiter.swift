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
    ///
    /// ## Two-Phase Initialization
    ///
    /// The waiter supports late-binding of the continuation to enable safe capture
    /// in `@Sendable` closures:
    /// ```swift
    /// let waiter = Waiter(token: token)  // Create before closure
    /// await withTaskCancellationHandler {
    ///     await withCheckedContinuation { continuation in
    ///         waiter.arm(continuation: continuation)  // Bind continuation
    ///         // enqueue waiter
    ///     }
    /// } onCancel: {
    ///     waiter.cancel()  // Safe: captures immutable `let waiter`
    /// }
    /// ```
    ///
    /// ## Thread Safety
    /// `@unchecked Sendable` because it provides internal synchronization via `Atomic`.
    internal final class Waiter: @unchecked Sendable {
        /// Atomic state for lock-free cancellation.
        private let state = Atomic<State>(.unarmed)

        /// The continuation. Set once during arm(), cleared once during takeForResume().
        /// Access is protected by state machine transitions.
        private var continuation: CheckedContinuation<Void, Never>?

        /// Unique token for identification in the waiter queue.
        internal let token: UInt64

        /// Creates an unarmed waiter ready to be captured and later armed.
        ///
        /// The waiter must be armed with `arm(continuation:)` before it can be drained.
        ///
        /// - Parameter token: Unique identifier for this waiter.
        internal init(token: UInt64) {
            self.token = token
        }
    }
}

extension IO.Handle.Waiter {
    /// Arm the waiter with a continuation. One-shot, thread-safe.
    ///
    /// This method binds the continuation to the waiter. It is safe to call
    /// even if `cancel()` was called first (cancel-before-arm race).
    ///
    /// - Parameter continuation: The continuation to resume when drained.
    /// - Returns: `true` if successfully armed, `false` if already armed.
    @discardableResult
    internal func arm(continuation: CheckedContinuation<Void, Never>) -> Bool {
        let succeeded =
            transition { current in
                switch current {
                case .unarmed: .armed
                case .cancelledUnarmed: .armedCancelled
                default: nil  // Already armed or drained
                }
            } != nil

        if succeeded {
            self.continuation = continuation
        }
        return succeeded
    }

    /// Mark this waiter as cancelled. Synchronous, lock-free.
    ///
    /// This method can be called from any thread, including `onCancel` handlers.
    /// It does NOT resume the continuation - that happens during actor drain.
    ///
    /// Safe to call before or after `arm()`.
    ///
    /// - Returns: `true` if successfully set cancelled flag.
    ///   `false` if already cancelled or already drained.
    @discardableResult
    internal func cancel() -> Bool {
        transition { current in
            guard !current.isCancelled && !current.isDrained else { return nil }
            return current.isArmed ? .armedCancelled : .cancelledUnarmed
        } != nil
    }
}

extension IO.Handle.Waiter {
    /// Check if this waiter was cancelled.
    ///
    /// Safe to call from any thread.
    internal var wasCancelled: Bool {
        state.load(ordering: .acquiring).isCancelled
    }

    /// Check if this waiter has been armed (continuation bound).
    ///
    /// Safe to call from any thread.
    internal var isArmed: Bool {
        state.load(ordering: .acquiring).isArmed
    }

    /// Check if this waiter has been drained (continuation taken).
    ///
    /// Safe to call from any thread.
    internal var isDrained: Bool {
        state.load(ordering: .acquiring).isDrained
    }

    /// Check if this waiter is eligible for handle reservation.
    ///
    /// A waiter is eligible if:
    /// - It has been armed (continuation bound)
    /// - It has not been cancelled
    /// - It has not been drained
    ///
    /// Safe to call from any thread.
    internal var isEligibleForReservation: Bool {
        let s = state.load(ordering: .acquiring)
        return s.isArmed && !s.isCancelled && !s.isDrained
    }
}

// MARK: - State Transition Primitive

extension IO.Handle.Waiter {
    /// Atomic state transition with CAS retry.
    ///
    /// This is the core primitive for all waiter state transitions. It:
    /// 1. Loads current state
    /// 2. Computes desired state via transform (nil = no valid transition)
    /// 3. Attempts CAS exchange
    /// 4. Retries on race, returns on success or invalid transition
    ///
    /// - Parameter transform: Maps current state to desired state, or nil if no valid transition.
    /// - Returns: The previous state if transition succeeded, nil if no valid transition.
    @discardableResult
    private func transition(_ transform: (State) -> State?) -> State? {
        while true {
            let current = state.load(ordering: .acquiring)
            guard let desired = transform(current) else { return nil }
            let (exchanged, _) = state.compareExchange(
                expected: current,
                desired: desired,
                ordering: .acquiringAndReleasing
            )
            if exchanged { return current }
        }
    }
}

// MARK: - Take Accessor

extension IO.Handle.Waiter {
    /// Accessor for take operations.
    internal struct Take {
        unowned let waiter: IO.Handle.Waiter

        /// Take the continuation for resumption. Actor-only operation.
        ///
        /// This method transitions the waiter to drained state and returns the
        /// continuation. The actor must resume the returned continuation.
        ///
        /// - Returns: The continuation if available, along with cancellation status.
        ///   Returns `nil` if not yet armed or already drained.
        internal func callAsFunction() -> (continuation: CheckedContinuation<Void, Never>, wasCancelled: Bool)? {
            forResume()
        }

        /// Take the continuation for resumption. Actor-only operation.
        internal func forResume() -> (continuation: CheckedContinuation<Void, Never>, wasCancelled: Bool)? {
            guard
                let previous = waiter.transition({ current in
                    guard current.isArmed && !current.isDrained else { return nil }
                    return current.isCancelled ? .cancelledDrained : .drained
                })
            else {
                return nil
            }

            // Take the continuation (only one caller can reach here per waiter)
            guard let c = waiter.continuation else {
                preconditionFailure("Waiter armed but continuation was nil")
            }
            waiter.continuation = nil

            return (c, previous.isCancelled)
        }
    }

    /// Accessor for take operations.
    internal var take: Take { Take(waiter: self) }
}
