//
//  IO.Handle.Waiters.Node.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 24/12/2025.
//

extension IO.Handle.Waiters {
    /// A single waiter node in the queue.
    struct Node {
        let token: UInt64
        let continuation: CheckedContinuation<Void, Never>
        var isCancelled: Bool = false

        init(token: UInt64, continuation: CheckedContinuation<Void, Never>) {
            self.token = token
            self.continuation = continuation
            self.isCancelled = false
        }
    }
}
