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
    /// ## Error Handling
    /// The continuation uses `any Error` due to Swift stdlib limitations
    /// (`withCheckedThrowingContinuation` doesn't support typed throws in Swift 6.2).
    /// However, `resumeThrowing` only accepts `IO.Blocking.Failure`, ensuring
    /// by construction that no other error types can escape.
    /// The `Box.Pointer` wrapper provides `@unchecked Sendable` capability at the FFI boundary.
    struct Waiter {
        /// Continuation type alias for clarity.
        typealias Continuation = CheckedContinuation<IO.Blocking.Box.Pointer, any Error>

        /// The continuation to resume with the boxed result or failure.
        let continuation: Continuation


    // - Cancellation path: removes waiter from dictionary and resumes with `.cancellationRequested`
    // - Completion path: removes waiter from dictionary and resumes with box
    //
    // Because both paths remove the waiter under lock before resuming,
    // only one can ever see and resume a given waiter.
    //
        /// Whether this waiter has been resumed. Used for DEBUG assertions only.
        var resumed: Bool

        init(
            continuation: Continuation,
            resumed: Bool = false
        ) {
            self.continuation = continuation
            self.resumed = resumed
        }

        /// Resume this waiter exactly once with the result.
        mutating func resumeReturning(_ box: IO.Blocking.Box.Pointer) {
            #if DEBUG
            precondition(!resumed, "Completion waiter resumed more than once")
            #endif
            resumed = true
            continuation.resume(returning: box)
        }

        /// Resume this waiter exactly once with a failure.
        ///
        /// Only accepts `IO.Blocking.Failure` to ensure by construction
        /// that no unexpected error types escape through the continuation.
        mutating func resumeThrowing(_ error: IO.Blocking.Failure) {
            #if DEBUG
            precondition(!resumed, "Completion waiter resumed more than once")
            #endif
            resumed = true
            continuation.resume(throwing: error)
        }
    }
}
