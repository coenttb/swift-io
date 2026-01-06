// ===----------------------------------------------------------------------===//
//
// This source file is part of the swift-io open source project
//
// Copyright (c) 2025 Coen ten Thije Boonkkamp and the swift-io project authors
// Licensed under Apache License v2.0
//
// See LICENSE for license information
//
// ===----------------------------------------------------------------------===//

extension IO.Event {
    /// Result of a poll operation, distinguishing events from control signals.
    ///
    /// This enum explicitly separates data (events) from control signals (tick),
    /// avoiding ambiguity in the bridge protocol.
    ///
    /// ## Usage
    /// ```swift
    /// // Poll thread
    /// if count > 0 {
    ///     bridge.push(.events(batch))
    /// } else {
    ///     bridge.push(.tick)  // Explicit control signal
    /// }
    ///
    /// // Selector
    /// switch await bridge.next() {
    /// case .events(let batch):
    ///     // Process events
    /// case .tick:
    ///     // Drain deadlines only
    /// case nil:
    ///     // Bridge finished
    /// }
    /// ```
    public enum Poll: Sendable {
        /// Events were returned from the OS poll.
        case events([IO.Event])

        /// No events, but poll returned (timeout/wakeup).
        ///
        /// This is a control signal for the selector to drain
        /// expired deadlines without processing events.
        case tick
    }
}
