//
//  IO.Blocking.Threads.State.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 06/01/2026.
//

extension IO.Blocking.Threads {
    /// Namespace for state-related types.
    public enum State {}
}

// MARK: - Transition

extension IO.Blocking.Threads.State {
    /// Queue state transitions for out-of-lock callbacks.
    ///
    /// ## Edge-Triggered Semantics
    /// Only emitted when state actually changes, not on every operation.
    ///
    /// ## Usage
    /// Configure via `Options.onStateTransition`. The callback is invoked
    /// **after** the lock is released, never while holding the lock.
    ///
    /// ## Warning
    /// Callback must be fast and non-blocking; it is invoked on
    /// enqueue/dequeue code paths and will affect throughput.
    public enum Transition: Sendable, Equatable {
        /// Queue transitioned from non-empty to empty.
        case becameEmpty

        /// Queue transitioned from empty to non-empty.
        case becameNonEmpty

        /// Queue became full (reached limit).
        case becameSaturated

        /// Queue is no longer full (below limit).
        case becameNotSaturated
    }
}
