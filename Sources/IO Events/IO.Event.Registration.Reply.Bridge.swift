//
//  IO.Event.Registration.Reply.Bridge.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 29/12/2025.
//

public import Async

extension IO.Event.Registration.Reply {
    /// Thread-safe bridge for poll thread → selector actor registration reply handoff.
    ///
    /// The `Bridge` transfers registration replies from the poll thread (synchronous)
    /// to the selector actor (async) without blocking.
    ///
    /// ## Pattern
    /// - Poll thread calls `push(_:)` (synchronous, never blocks)
    /// - Selector actor calls `next()` (async, suspends until reply available)
    ///
    /// ## Thread Safety
    /// All operations are protected by internal synchronization.
    public typealias Bridge = Async.Bridge<IO.Event.Registration.Reply>
}
