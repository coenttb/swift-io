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
    /// After shutdown, pushes are silently ignored.
    ///
    /// - Parameter events: The batch of events to deliver.
    public func push(_ events: [IO.NonBlocking.Event]) {
        // Extract continuation inside lock, resume OUTSIDE lock
        let continuationToResume: CheckedContinuation<[IO.NonBlocking.Event]?, Never>? = state.withLock { state in
            guard !state.isShutdown else { return nil }  // Ignore push after shutdown
            if let cont = state.continuation {
                state.continuation = nil
                return cont
            } else {
                state.batches.append(events)
                return nil
            }
        }
        continuationToResume?.resume(returning: events)
    }

    /// Wait for next event batch (async, suspends if none available).
    ///
    /// Called by selector actor on its executor.
    ///
    /// - Returns: The next batch of events, or `nil` if shutdown.
    public func next() async -> [IO.NonBlocking.Event]? {
        enum Action {
            case returnNil
            case returnBatch([IO.NonBlocking.Event])
            case suspend
        }

        return await withCheckedContinuation { continuation in
            let action: Action = state.withLock { state in
                if state.isShutdown { return .returnNil }
                if let batch = state.batches.first {
                    state.batches.removeFirst()
                    return .returnBatch(batch)
                }
                state.continuation = continuation
                return .suspend
            }
            // Resume OUTSIDE lock
            switch action {
            case .returnNil: continuation.resume(returning: nil)
            case .returnBatch(let batch): continuation.resume(returning: batch)
            case .suspend: break  // Will be resumed by push() or shutdown()
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
        // Extract continuation inside lock, resume OUTSIDE lock
        let continuationToResume: CheckedContinuation<[IO.NonBlocking.Event]?, Never>? = state.withLock { state in
            state.isShutdown = true
            if let cont = state.continuation {
                state.continuation = nil
                return cont
            }
            return nil
        }
        continuationToResume?.resume(returning: nil)
    }

    /// Check if the bridge has been shut down.
    public var isShutdown: Bool {
        state.withLock { $0.isShutdown }
    }
}
