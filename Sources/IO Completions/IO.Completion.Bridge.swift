//
//  IO.Completion.Bridge.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 31/12/2025.
//

public import Dimension
public import Runtime

extension IO.Completion {
    /// Thread-safe bridge for poll thread → queue actor event handoff.
    ///
    /// Delegates to `Runtime.Async.Bridge` with batch semantics.
    /// Poll thread pushes event batches, queue actor receives batches.
    ///
    /// Access underlying API via `.rawValue`:
    /// - `bridge.rawValue.push(events)` - push batch from poll thread
    /// - `await bridge.rawValue.next()` - receive batch in queue actor
    /// - `bridge.rawValue.finish()` - signal shutdown
    public typealias Bridge = Tagged<IO.Completion, Runtime.Async.Bridge<[Event]>>
}
