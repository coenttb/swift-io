//
//  IO.Event.Registration.Queue+Methods.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 28/12/2025.
//

internal import Synchronization

extension IO.Event.Registration.Queue {
    /// Enqueue a registration request.
    ///
    /// Safe to call from any thread (typically the selector actor).
    ///
    /// - Parameter request: The request to enqueue.
    public func enqueue(_ request: IO.Event.Registration.Request) {
        state.withLock { state in
            guard !state.isShutdown else { return }
            state.requests.append(request)
        }
    }

    /// Dequeue a single request (FIFO order).
    ///
    /// Safe to call from any thread (typically the poll thread).
    ///
    /// - Returns: The next request, or `nil` if the queue is empty.
    public func dequeue() -> IO.Event.Registration.Request? {
        state.withLock { state in
            guard !state.requests.isEmpty else { return nil }
            return state.requests.removeFirst()
        }
    }

    /// Dequeue all pending requests.
    ///
    /// Used during shutdown to process remaining requests.
    ///
    /// - Returns: All pending requests.
    public func dequeueAll() -> [IO.Event.Registration.Request] {
        state.withLock { state in
            let requests = state.requests
            state.requests.removeAll()
            return requests
        }
    }

    /// Check if there are pending requests.
    public var hasPending: Bool {
        state.withLock { !$0.requests.isEmpty }
    }

    /// Signal shutdown.
    ///
    /// After this call, new enqueue requests are silently ignored.
    public func shutdown() {
        state.withLock { state in
            state.isShutdown = true
        }
    }
}
