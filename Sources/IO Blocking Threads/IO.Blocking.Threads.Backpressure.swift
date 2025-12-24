//
//  IO.Blocking.Threads.Backpressure.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 24/12/2025.
//

extension IO.Blocking.Threads {
    /// Backpressure policy when the queue is full.
    public enum Backpressure: Sendable {
        /// Suspend the caller until capacity is available.
        ///
        /// Bounded by the deadline if provided.
        case suspend

        /// Throw `.queueFull` immediately.
        case `throw`
    }
}
