//
//  IO.Event.Registration.Queue.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 28/12/2025.
//

public import Synchronization
public import Buffer

/// Thread-safe shared queue with MPSC semantics.
public typealias Queue<T> = Shared<Mutex<Deque<T>>>

extension IO.Event.Registration {
    /// Thread-safe queue for registration requests from selector to poll thread.
    public typealias Queue = IO_Events.Queue<IO.Event.Registration.Request>
}
