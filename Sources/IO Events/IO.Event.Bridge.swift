//
//  IO.Event.Bridge.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 28/12/2025.
//

public import Runtime

extension IO.Event {
    /// Thread-safe bridge for poll thread → selector actor event handoff.
    ///
    /// The `Bridge` transfers `IO.Event.Poll` values from the poll thread
    /// (synchronous) to the selector actor (async).
    ///
    /// ## Pattern
    /// - Poll thread calls `push(.events(batch))` or `push(.tick)`
    /// - Selector actor calls `next()` (async, suspends until available)
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
    ///
    /// ## Thread Safety
    /// All operations are protected by internal synchronization.
    public typealias Bridge = Runtime.Async.Bridge<IO.Event.Poll>
}
