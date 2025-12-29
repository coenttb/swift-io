//
//  IO.NonBlocking.Event.Bridge+Methods.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 28/12/2025.
//

internal import Synchronization

extension IO.NonBlocking.Event.Bridge {
    /// Push events from poll thread (synchronous, non-blocking).
    ///
    /// If the selector is awaiting via `next()`, resumes it immediately
    /// with the events. Otherwise, queues the batch for later consumption.
    ///
    /// This method is safe to call from any thread, including the poll thread.
    ///
    /// - Parameter events: The batch of events to deliver.
    public func push(_ events: [IO.NonBlocking.Event]) {
        state.withLock { state in
            if let cont = state.continuation {
                state.continuation = nil
                cont.resume(returning: events)
            } else {
                state.batches.append(events)
            }
        }
    }

    /// Wait for next event batch (async, suspends if none available).
    ///
    /// Called by selector actor on its executor.
    ///
    /// - Returns: The next batch of events, or `nil` if shutdown.
    public func next() async -> [IO.NonBlocking.Event]? {
        await withCheckedContinuation { continuation in
            state.withLock { state in
                if state.isShutdown {
                    continuation.resume(returning: nil)
                } else if let batch = state.batches.first {
                    state.batches.removeFirst()
                    continuation.resume(returning: batch)
                } else {
                    state.continuation = continuation
                }
            }
        }
    }

    /// Signal shutdown (poll thread or selector can call).
    ///
    /// After this call:
    /// - Any pending `next()` returns `nil`
    /// - Future `next()` calls return `nil` immediately
    /// - Future `push()` calls are silently ignored
    public func shutdown() {
        state.withLock { state in
            state.isShutdown = true
            if let cont = state.continuation {
                state.continuation = nil
                cont.resume(returning: nil)
            }
        }
    }

    /// Check if the bridge has been shut down.
    public var isShutdown: Bool {
        state.withLock { $0.isShutdown }
    }
}
