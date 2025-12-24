//
//  IO.Handle.Waiters.Node.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 24/12/2025.
//

extension IO.Handle.Waiters {
    /// A single waiter node in the queue.
    public struct Node {
        public let token: UInt64
        public let continuation: CheckedContinuation<Void, Never>
        public var isCancelled: Bool = false

        public init(token: UInt64, continuation: CheckedContinuation<Void, Never>) {
            self.token = token
            self.continuation = continuation
            self.isCancelled = false
        }
    }
}
