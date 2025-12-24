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
    /// If the caller cancels, the waiter is marked `abandoned` so the
    /// completion handler knows to free the result instead of resuming.
    struct Waiter {
        /// The continuation to resume with the result pointer.
        let continuation: CheckedContinuation<UnsafeMutableRawPointer, Never>

        /// Whether the waiter has been abandoned due to cancellation.
        /// If true, the completion should free the result instead of resuming.
        var abandoned: Bool

        /// Whether this waiter has been resumed. Used for DEBUG assertions.
        var resumed: Bool

        init(
            continuation: CheckedContinuation<UnsafeMutableRawPointer, Never>,
            abandoned: Bool = false,
            resumed: Bool = false
        ) {
            self.continuation = continuation
            self.abandoned = abandoned
            self.resumed = resumed
        }

        /// Resume this waiter exactly once with the result.
        ///
        /// - Precondition: Must not have been resumed before.
        /// - Precondition: Must not be abandoned.
        mutating func resumeReturning(_ box: sending UnsafeMutableRawPointer) {
            #if DEBUG
            precondition(!resumed, "Completion waiter resumed more than once")
            precondition(!abandoned, "Completion waiter resumed after abandonment")
            #endif
            resumed = true
            continuation.resume(returning: box)
        }
    }
}
