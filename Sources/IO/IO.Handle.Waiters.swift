//
//  IO.Handle.Waiters.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 24/12/2025.
//

extension IO.Handle {
    /// FIFO queue of tasks waiting for a handle.
    ///
    /// Implements the cancellation-safe waiter pattern:
    /// - Waiters are marked cancelled rather than removed immediately
    /// - Resume logic skips cancelled waiters
    /// - Only one waiter is resumed at a time (no thundering herd)
    public struct Waiters {
        private var nodes: [Node] = []
        private var nextToken: UInt64 = 0

        public init() {}

        public mutating func generateToken() -> UInt64 {
            let token = nextToken
            nextToken += 1
            return token
        }

        public mutating func enqueue(token: UInt64, continuation: CheckedContinuation<Void, Never>) {
            nodes.append(Node(token: token, continuation: continuation))
        }

        /// Mark a waiter as cancelled by token.
        /// Returns the continuation if found and not already cancelled.
        public mutating func cancel(token: UInt64) -> CheckedContinuation<Void, Never>? {
            for i in nodes.indices {
                if nodes[i].token == token && !nodes[i].isCancelled {
                    nodes[i].isCancelled = true
                    return nodes[i].continuation
                }
            }
            return nil
        }

        /// Resume exactly one non-cancelled waiter.
        /// Skips cancelled waiters (they were already resumed with cancellation).
        public mutating func resumeNext() {
            while let first = nodes.first {
                nodes.removeFirst()
                if !first.isCancelled {
                    first.continuation.resume()
                    return
                }
            }
        }

        public var isEmpty: Bool { nodes.isEmpty }

        public mutating func resumeAll() {
            for node in nodes where !node.isCancelled {
                node.continuation.resume()
            }
            nodes.removeAll()
        }
    }
}
