//
//  IO.Backpressure.Strategy.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 24/12/2025.
//

extension IO.Backpressure {
    /// Strategy for handling queue-full conditions.
    public enum Strategy: Sendable, Equatable {
        /// Suspend the caller until capacity is available.
        ///
        /// Bounded by deadline if provided.
        case wait

        /// Fail immediately when queue is full.
        ///
        /// Throws the appropriate error for the layer:
        /// - Lane: `.queueFull`
        /// - Handle: `.waitersFull`
        case failFast
    }
}
