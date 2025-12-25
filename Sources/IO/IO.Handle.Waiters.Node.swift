//
//  IO.Handle.Waiters.Node.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 24/12/2025.
//

extension IO.Handle.Waiters {
    /// A single waiter node in the queue.
    ///
    /// ## Exactly-Once Resumption
    ///
    /// The continuation is stored as optional and nil'd out when consumed.
    /// This makes double-resume structurally impossible:
    /// - `takeContinuation()` returns and nils the continuation atomically
    /// - Subsequent calls return nil
    /// - Resume operations check for nil before resuming
    ///
    /// This is a stronger guarantee than just the `isCancelled` flag,
    /// catching internal bugs at the point of misuse rather than silently
    /// double-resuming.
    struct Node {
        let token: UInt64
        /// The continuation, or nil if already consumed (resumed or cancelled).
        var continuation: CheckedContinuation<Void, Never>?
        var isCancelled: Bool = false

        init(token: UInt64, continuation: CheckedContinuation<Void, Never>) {
            self.token = token
            self.continuation = continuation
            self.isCancelled = false
        }

        /// Takes the continuation, returning it and setting to nil.
        ///
        /// Returns nil if already taken. This ensures exactly-once consumption.
        mutating func takeContinuation() -> CheckedContinuation<Void, Never>? {
            let c = continuation
            continuation = nil
            return c
        }
    }
}
