//
//  IO.Completion.Waiter.Take.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 31/12/2025.
//

import Synchronization

extension IO.Completion.Waiter {
    /// Take operations for draining the waiter.
    public struct Take {
        let waiter: IO.Completion.Waiter

        /// Takes the continuation for resumption.
        ///
        /// Called by the queue actor to get the continuation and resume it.
        ///
        /// - Returns: The Void continuation and whether it was cancelled, or nil if already drained.
        public func forResume() -> (
            continuation: CheckedContinuation<Void, Never>,
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
}
