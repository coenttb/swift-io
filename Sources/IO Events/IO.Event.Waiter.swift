//
//  IO.Event.Waiter.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 29/12/2025.
//

import Synchronization

extension IO.Event {
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
    /// ## Two-Phase Initialization
    ///
    /// The waiter supports late-binding of the continuation to enable safe capture
    /// in `@Sendable` closures:
    /// ```swift
    /// let waiter = Waiter(id: id)  // Create before closure
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
    /// ## State Machine
    /// ```
    /// unarmed ─────arm()─────▶ armed ──cancel()──▶ armedCancelled
    ///    │                       │                      │
    ///    │cancel()               │                      │
    ///    ▼                       ▼                      ▼
    /// cancelledUnarmed       takeForResume()       takeForResume()
    ///    │                       │                      │
    ///    │arm()                  ▼                      ▼
    ///    ▼                    drained            cancelledDrained
    /// armedCancelled
    /// ```
    ///
    /// ## Typed Errors via Result
    ///
    /// Uses `CheckedContinuation<Result<IO.Event, Failure>, Never>` instead of throwing
    /// continuation. This eliminates all `any Error` handling and makes typed throws
    /// work by construction.
    ///
    /// ## Thread Safety
    /// `@unchecked Sendable` because it provides internal synchronization via `Atomic`.
    public final class Waiter: @unchecked Sendable {
        /// Internal state representation.
        ///
        /// Uses bit patterns for atomic operations:
        /// - Bit 0: cancelled flag
        /// - Bit 1: armed flag (continuation bound)
        /// - Bit 2: drained flag (continuation taken)
        struct State: RawRepresentable, AtomicRepresentable, Equatable {
            var rawValue: UInt8

            static let unarmed = State(rawValue: 0b000)
            static let cancelledUnarmed = State(rawValue: 0b001)
            static let armed = State(rawValue: 0b010)
            static let armedCancelled = State(rawValue: 0b011)
            static let drained = State(rawValue: 0b110)
            static let cancelledDrained = State(rawValue: 0b111)

            var isCancelled: Bool { rawValue & 0b001 != 0 }
            var isArmed: Bool { rawValue & 0b010 != 0 }
            var isDrained: Bool { rawValue & 0b100 != 0 }

            init(rawValue: UInt8) {
                self.rawValue = rawValue
            }
        }

        /// Atomic state for lock-free cancellation.
        let _state: Atomic<State>

        /// The continuation. Set once during arm(), cleared once during takeForResume().
        /// Access is protected by state machine transitions.
        ///
        /// Uses non-throwing continuation with Result payload to achieve typed errors
        /// without relying on Swift's untyped `withCheckedThrowingContinuation`.
        var continuation: CheckedContinuation<Result<IO.Event, Failure>, Never>?

        /// The registration ID this waiter is waiting on.
        public let id: ID

        /// Creates an unarmed waiter ready to be captured and later armed.
        ///
        /// The waiter must be armed with `arm(continuation:)` before it can be drained.
        ///
        /// - Parameter id: The registration ID this waiter is waiting on.
        public init(id: ID) {
            self.id = id
            self._state = Atomic(.unarmed)
        }
    }
}
