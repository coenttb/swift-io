//
//  IO.Event.Registration.Queue.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 28/12/2025.
//

public import Runtime

extension IO.Event.Registration {
    /// Thread-safe queue for registration requests from selector to poll thread.
    ///
    /// The `Queue` allows the selector actor to enqueue registration requests
    /// that the poll thread processes between poll cycles.
    ///
    /// ## Thread Safety
    /// All operations are protected by internal synchronization.
    ///
    /// ## Pattern
    /// - Selector enqueues requests via `enqueue(_:)`
    /// - Poll thread dequeues via `dequeue.one()` or `dequeue()`
    /// - Shutdown drains remaining requests via `dequeue.all()`
    public typealias Queue = Runtime.Mutex.Queue<IO.Event.Registration.Request>
}
