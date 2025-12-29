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
    /// ## Thread Safety
    /// `@unchecked Sendable` because it provides internal synchronization via `Atomic`.
    public final class Waiter: @unchecked Sendable {
        /// Internal state representation.
        ///
        /// Uses bit patterns for atomic operations:
        /// - Bit 0: cancelled flag
        /// - Bit 1: armed flag (continuation bound)
        /// - Bit 2: drained flag (continuation taken)
        private struct State: RawRepresentable, AtomicRepresentable, Equatable {
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
        private let state = Atomic<State>(.unarmed)

        /// The continuation. Set once during arm(), cleared once during takeForResume().
        /// Access is protected by state machine transitions.
        private var continuation: CheckedContinuation<Void, Never>?

        /// Unique token for identification in the waiter queue.
        public let token: UInt64

        /// Creates an unarmed waiter ready to be captured and later armed.
        ///
        /// The waiter must be armed with `arm(continuation:)` before it can be drained.
        ///
        /// - Parameter token: Unique identifier for this waiter.
        public init(token: UInt64) {
            self.token = token
        }

        /// Arm the waiter with a continuation. One-shot, thread-safe.
        ///
        /// This method binds the continuation to the waiter. It is safe to call
        /// even if `cancel()` was called first (cancel-before-arm race).
        ///
        /// - Parameter continuation: The continuation to resume when drained.
        /// - Returns: `true` if successfully armed, `false` if already armed.
        @discardableResult
        public func arm(continuation: CheckedContinuation<Void, Never>) -> Bool {
            // Try: unarmed → armed
            var (exchanged, current) = state.compareExchange(
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
                (exchanged, _) = state.compareExchange(
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
                let current = state.load(ordering: .acquiring)

                // Already cancelled or drained
                if current.isCancelled || current.isDrained {
                    return false
                }

                let desired: State = current.isArmed ? .armedCancelled : .cancelledUnarmed
                let (exchanged, _) = state.compareExchange(
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
            state.load(ordering: .acquiring).isCancelled
        }

        /// Check if this waiter has been armed (continuation bound).
        ///
        /// Safe to call from any thread.
        public var isArmed: Bool {
            state.load(ordering: .acquiring).isArmed
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
        ///   Returns `nil` if not yet armed or already drained.
        public func takeForResume() -> (continuation: CheckedContinuation<Void, Never>, wasCancelled: Bool)? {
            while true {
                let current = state.load(ordering: .acquiring)

                // Not armed yet or already drained
                if !current.isArmed || current.isDrained {
                    return nil
                }

                let desired: State = current.isCancelled ? .cancelledDrained : .drained
                let (exchanged, _) = state.compareExchange(
                    expected: current,
                    desired: desired,
                    ordering: .acquiringAndReleasing
                )

                guard exchanged else {
                    // Race - retry
                    continue
                }

                // Take the continuation (only one caller can reach here per waiter)
                guard let c = continuation else {
                    preconditionFailure("Waiter armed but continuation was nil")
                }
                continuation = nil

                return (c, current.isCancelled)
            }
        }
    }
}
