//
//  IO.Event.Waiter+Methods.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 29/12/2025.
//

internal import Synchronization

extension IO.Event.Waiter {
    /// Arm the waiter with a continuation. One-shot, thread-safe.
    ///
    /// This method binds the continuation to the waiter. It is safe to call
    /// even if `cancel()` was called first (cancel-before-arm race).
    ///
    /// Uses non-throwing continuation with Result payload to achieve typed errors
    /// without relying on Swift's untyped `withCheckedThrowingContinuation`.
    ///
    /// - Parameter continuation: The continuation to resume when drained.
    /// - Returns: `true` if successfully armed, `false` if already armed.
    @discardableResult
    public func arm(continuation: CheckedContinuation<Result<IO.Event, IO.Event.Failure>, Never>) -> Bool {
        // Try: unarmed → armed
        var (exchanged, current) = _state.compareExchange(
            expected: .unarmed,
            desired: .armed,
            ordering: .acquiringAndReleasing
        )

        if exchanged {
            self.continuation = continuation
            return true
        }

        // Try: cancelledUnarmed → armedCancelled (cancel-before-arm case)
        if current == .cancelledUnarmed {
            (exchanged, _) = _state.compareExchange(
                expected: .cancelledUnarmed,
                desired: .armedCancelled,
                ordering: .acquiringAndReleasing
            )
            if exchanged {
                self.continuation = continuation
                return true
            }
            // Retry if race
            return arm(continuation: continuation)
        }

        // Already armed or drained
        return false
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
    public func cancel() -> Bool {
        while true {
            let current = _state.load(ordering: .acquiring)

            // Already cancelled or drained
            if current.isCancelled || current.isDrained {
                return false
            }

            let desired: State = current.isArmed ? .armedCancelled : .cancelledUnarmed
            let (exchanged, _) = _state.compareExchange(
                expected: current,
                desired: desired,
                ordering: .acquiringAndReleasing
            )

            if exchanged {
                return true
            }
            // Retry on race
        }
    }

    /// Check if this waiter was cancelled.
    ///
    /// Safe to call from any thread.
    public var wasCancelled: Bool {
        _state.load(ordering: .acquiring).isCancelled
    }

    /// Check if this waiter has been armed (continuation bound).
    ///
    /// Safe to call from any thread.
    public var isArmed: Bool {
        _state.load(ordering: .acquiring).isArmed
    }

    /// Check if this waiter has been drained (continuation taken).
    ///
    /// Safe to call from any thread.
    public var isDrained: Bool {
        _state.load(ordering: .acquiring).isDrained
    }

}

// MARK: - Take Accessor

extension IO.Event.Waiter {
    /// Accessor for take operations.
    public struct Take {
        unowned let waiter: IO.Event.Waiter

        /// Take the continuation for resumption. Actor-only operation.
        ///
        /// This method transitions the waiter to drained state and returns the
        /// continuation. The actor must resume the returned continuation with
        /// a `Result<Event, Failure>`.
        ///
        /// - Returns: The continuation if available, along with cancellation status.
        ///   Returns `nil` if not yet armed or already drained.
        public func callAsFunction() -> (continuation: CheckedContinuation<Result<IO.Event, IO.Event.Failure>, Never>, wasCancelled: Bool)? {
            forResume()
        }

        /// Take the continuation for resumption. Actor-only operation.
        public func forResume() -> (continuation: CheckedContinuation<Result<IO.Event, IO.Event.Failure>, Never>, wasCancelled: Bool)? {
            while true {
                let current = waiter._state.load(ordering: .acquiring)

                // Not armed yet or already drained
                if !current.isArmed || current.isDrained {
                    return nil
                }

                let desired: State = current.isCancelled ? .cancelledDrained : .drained
                let (exchanged, _) = waiter._state.compareExchange(
                    expected: current,
                    desired: desired,
                    ordering: .acquiringAndReleasing
                )

                guard exchanged else {
                    // Race - retry
                    continue
                }

                // Take the continuation (only one caller can reach here per waiter)
                guard let c = waiter.continuation else {
                    preconditionFailure("Waiter armed but continuation was nil")
                }
                waiter.continuation = nil

                return (c, current.isCancelled)
            }
        }
    }

    /// Accessor for take operations.
    public var take: Take { Take(waiter: self) }
}
