//
//  IO.Completion.Waiter.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 31/12/2025.
//

import Synchronization

@_exported public import IO_Completions_Driver

extension IO.Completion {
    /// Thread-safe waiter cell with synchronous cancellation intent.
    ///
    /// ## Cancellation Model: "Synchronous state flip, actor drains on next touch"
    ///
    /// - `cancel()` flips the cancelled bit synchronously from any thread (onCancel handler)
    /// - `cancel()` does NOT resume the continuation
    /// - The queue calls `takeForResume()` during drain to get the continuation
    /// - The queue resumes the continuation on its executor
    ///
    /// This ensures:
    /// - Single funnel for continuation resumption (queue actor only)
    /// - No "resume under lock" hazards
    /// - No continuation resumed from arbitrary cancellation threads
    ///
    /// ## Two-Phase Initialization
    ///
    /// The waiter supports late-binding of the continuation:
    /// ```swift
    /// let waiter = Waiter(id: id)  // Create before closure
    /// await withTaskCancellationHandler {
    ///     await withCheckedContinuation { continuation in
    ///         waiter.arm(continuation: continuation)
    ///     }
    /// } onCancel: {
    ///     waiter.cancel()  // Safe: captures immutable `let waiter`
    /// }
    /// ```
    ///
    /// ## Typed Continuation
    ///
    /// Uses `CheckedContinuation<IO.Completion.ID, Never>` - a Copyable signal type.
    /// The continuation carries only the operation ID; the actor extracts the buffer
    /// and event from storage after await. This satisfies Swift's Copyable constraint
    /// on continuation payloads.
    ///
    /// ## Thread Safety
    ///
    /// `@unchecked Sendable` because it provides internal synchronization via `Atomic`.
    public final class Waiter: @unchecked Sendable {
        /// Internal state representation.
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
        ///
        /// Uses non-throwing continuation with Copyable ID to satisfy Swift's constraint.
        var continuation: CheckedContinuation<IO.Completion.ID, Never>?

        /// The operation ID this waiter is waiting on.
        public let id: IO.Completion.ID

        /// Creates an unarmed waiter.
        public init(id: IO.Completion.ID) {
            self.id = id
            self._state = Atomic(.unarmed)
        }

        /// Arms the waiter with a continuation.
        ///
        /// - Parameter continuation: The continuation to resume on completion.
        /// - Returns: `true` if armed successfully, `false` if already cancelled.
        ///
        /// If cancelled before arming, returns false and caller should
        /// resume the continuation with cancellation immediately.
        @discardableResult
        public func arm(
            continuation: CheckedContinuation<IO.Completion.ID, Never>
        ) -> Bool {
            let (exchanged, original) = _state.compareExchange(
                expected: .unarmed,
                desired: .armed,
                ordering: .acquiringAndReleasing
            )

            if exchanged {
                self.continuation = continuation
                return true
            }

            // Was already cancelled
            if original == .cancelledUnarmed {
                // Transition to armedCancelled
                _state.store(.armedCancelled, ordering: .releasing)
                self.continuation = continuation
                return false
            }

            // Invalid state (already armed)
            preconditionFailure("Waiter armed twice")
        }

        /// Marks the waiter as cancelled.
        ///
        /// This is called from the cancellation handler. It does NOT
        /// resume the continuation - that's done by the queue actor.
        public func cancel() {
            while true {
                let current = _state.load(ordering: .acquiring)

                switch current {
                case .unarmed:
                    let (exchanged, _) = _state.compareExchange(
                        expected: current,
                        desired: .cancelledUnarmed,
                        ordering: .acquiringAndReleasing
                    )
                    if exchanged { return }

                case .armed:
                    let (exchanged, _) = _state.compareExchange(
                        expected: current,
                        desired: .armedCancelled,
                        ordering: .acquiringAndReleasing
                    )
                    if exchanged { return }

                case .cancelledUnarmed, .armedCancelled, .drained, .cancelledDrained:
                    // Already cancelled or completed
                    return

                default:
                    return
                }
            }
        }

        /// Namespace for take operations.
        public var take: Take { Take(waiter: self) }

        /// Namespace for resume operations.
        public var resume: Resume { Resume(waiter: self) }

        /// Resume operations for the waiter.
        ///
        /// Provides a single point for resuming the waiter's continuation.
        /// This ensures state consumption is centralized and prevents
        /// double-resume bugs.
        public struct Resume {
            let waiter: Waiter

            /// Resumes the waiter with the given ID.
            ///
            /// This method consumes the waiter state and resumes the continuation
            /// exactly once. Safe to call from submit() for early completion handling.
            ///
            /// - Parameter id: The operation ID to resume with.
            /// - Returns: `true` if resumed, `false` if already drained or not armed.
            @discardableResult
            public func id(_ id: IO.Completion.ID) -> Bool {
                if let (cont, _) = waiter.take.forResume() {
                    cont.resume(returning: id)
                    return true
                }
                return false
            }
        }

        /// Take operations for draining the waiter.
        public struct Take {
            let waiter: Waiter

            /// Takes the continuation for resumption.
            ///
            /// Called by the queue actor to get the continuation and resume it.
            ///
            /// - Returns: The continuation and whether it was cancelled, or nil if already drained.
            public func forResume() -> (
                continuation: CheckedContinuation<IO.Completion.ID, Never>,
                cancelled: Bool
            )? {
                while true {
                    let current = waiter._state.load(ordering: .acquiring)

                    switch current {
                    case .armed:
                        let (exchanged, _) = waiter._state.compareExchange(
                            expected: current,
                            desired: .drained,
                            ordering: .acquiringAndReleasing
                        )
                        if exchanged {
                            guard let cont = waiter.continuation else {
                                preconditionFailure("Armed waiter has no continuation")
                            }
                            waiter.continuation = nil
                            return (cont, false)
                        }

                    case .armedCancelled:
                        let (exchanged, _) = waiter._state.compareExchange(
                            expected: current,
                            desired: .cancelledDrained,
                            ordering: .acquiringAndReleasing
                        )
                        if exchanged {
                            guard let cont = waiter.continuation else {
                                preconditionFailure("Armed waiter has no continuation")
                            }
                            waiter.continuation = nil
                            return (cont, true)
                        }

                    case .drained, .cancelledDrained:
                        // Already drained
                        return nil

                    case .unarmed, .cancelledUnarmed:
                        // Not yet armed, wait
                        return nil

                    default:
                        return nil
                    }
                }
            }
        }

        /// Whether the waiter has been cancelled.
        public var wasCancelled: Bool {
            _state.load(ordering: .acquiring).isCancelled
        }

        /// Whether the waiter is armed.
        public var isArmed: Bool {
            _state.load(ordering: .acquiring).isArmed
        }
    }
}
