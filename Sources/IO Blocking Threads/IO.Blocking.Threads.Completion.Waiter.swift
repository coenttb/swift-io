//
//  IO.Blocking.Threads.Completion.Waiter.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 24/12/2025.
//

extension IO.Blocking.Threads.Completion {
    /// A waiter for job completion.
    ///
    /// Created when a caller awaits completion of an accepted job.
    ///
    /// ## Continuation Resumption Invariant
    /// The continuation MUST be resumed exactly once. This is enforced by:
    /// - Cancellation path: removes waiter from dictionary and resumes with `.cancelled`
    /// - Completion path: removes waiter from dictionary and resumes with box
    ///
    /// Because both paths remove the waiter under lock before resuming,
    /// only one can ever see and resume a given waiter.
    ///
    /// ## Typed Throws via Result
    /// Uses `CheckedContinuation<Result<BoxPointer, Failure>, Never>` instead of
    /// `CheckedContinuation<BoxPointer, any Error>` to preserve typed throws.
    /// The continuation never throws; errors flow through the Result type.
    /// This avoids `any Error` leaking into storage types.
    struct Waiter {
        /// Result type for completion outcomes.
        typealias Outcome = Result<IO.Blocking.Box.Pointer, IO.Blocking.Failure>

        /// Continuation type - never throws, errors in Result.
        typealias Continuation = CheckedContinuation<Outcome, Never>

        /// The continuation to resume with the boxed result or failure.
        let continuation: Continuation

        /// Whether this waiter has been resumed. Used for DEBUG assertions only.
        var resumed: Bool

        init(
            continuation: Continuation,
            resumed: Bool = false
        ) {
            self.continuation = continuation
            self.resumed = resumed
        }

        /// Resume this waiter exactly once with the given outcome.
        ///
        /// - Precondition: Must not have been resumed before.
        mutating func resume(with outcome: Outcome) {
            #if DEBUG
            precondition(!resumed, "Completion waiter resumed more than once")
            #endif
            resumed = true
            continuation.resume(returning: outcome)
        }
    }
}
