//
//  IO.Completion.Waiter.Resume.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 31/12/2025.
//

extension IO.Completion.Waiter {
    /// Resume operations for the waiter.
    ///
    /// Provides a single point for resuming the waiter's continuation.
    /// This ensures state consumption is centralized and prevents
    /// double-resume bugs.
    public struct Resume {
        let waiter: IO.Completion.Waiter

        /// Resumes the waiter.
        ///
        /// This method consumes the waiter state and resumes the Void continuation
        /// exactly once. Safe to call from submit() for early completion handling
        /// or from onCancel for cancellation.
        ///
        /// - Returns: `true` if resumed, `false` if already drained or not armed.
        @discardableResult
        public func now() -> Bool {
            if let (cont, _) = waiter.take.forResume() {
                cont.resume()
                return true
            }
            return false
        }
    }
}
