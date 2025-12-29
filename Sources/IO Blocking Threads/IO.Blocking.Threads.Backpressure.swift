//
//  IO.Blocking.Threads.Backpressure.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 24/12/2025.
//

extension IO.Blocking.Threads {
    /// Backpressure policy when the queue is full.
    ///
    /// - Note: Prefer using `IO.Backpressure.Strategy` for new code.
    ///   This type is maintained for backward compatibility.
    public enum Backpressure: Sendable {
        /// Suspend the caller until capacity is available.
        ///
        /// Bounded by the deadline if provided.
        case suspend

        /// Throw `.queueFull` immediately.
        case `throw`

        /// Converts to unified backpressure strategy.
        public var strategy: IO.Backpressure.Strategy {
            switch self {
            case .suspend: return .wait
            case .throw: return .failFast
            }
        }
    }
}
