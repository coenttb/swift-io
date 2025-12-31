//
//  IO.Event.Registration.Reply.Bridge.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 29/12/2025.
//

import Synchronization

extension IO.Event.Registration.Reply {
    /// Thread-safe bridge for poll thread → selector actor registration reply handoff.
    ///
    /// The `Bridge` transfers registration replies from the poll thread (synchronous)
    /// to the selector actor (async) without blocking and without resuming under lock.
    ///
    /// ## Pattern
    /// - Poll thread calls `push(_:)` (synchronous, never blocks)
    /// - Selector actor calls `next()` (async, suspends until reply available)
    ///
    /// ## Thread Safety
    /// `@unchecked Sendable` because it provides internal synchronization via `Mutex`.
    ///
    /// ## Resume-Outside-Lock
    /// All continuation resumptions happen outside the lock to prevent deadlocks.
    public final class Bridge: @unchecked Sendable {
        let state: Mutex<State>

        struct State {
            var replies: [IO.Event.Registration.Reply] = []
            var continuation: CheckedContinuation<IO.Event.Registration.Reply?, Never>?
            var isShutdown: Bool = false
        }

        /// Creates a new reply bridge.
        public init() {
            self.state = Mutex(State())
        }
    }
}

// MARK: - Methods

extension IO.Event.Registration.Reply.Bridge {
    /// Push a reply from poll thread (synchronous, non-blocking).
    ///
    /// If the selector is awaiting via `next()`, resumes it immediately
    /// with the reply. Otherwise, queues the reply for later consumption.
    /// After shutdown, pushes are silently ignored.
    ///
    /// - Parameter reply: The reply to deliver.
    public func push(_ reply: IO.Event.Registration.Reply) {
        // Extract continuation inside lock, resume OUTSIDE lock
        let continuationToResume: CheckedContinuation<IO.Event.Registration.Reply?, Never>? = state.withLock { state in
            guard !state.isShutdown else { return nil }
            if let cont = state.continuation {
                state.continuation = nil
                return cont
            } else {
                state.replies.append(reply)
                return nil
            }
        }
        continuationToResume?.resume(returning: reply)
    }

    /// Wait for next reply (async, suspends if none available).
    ///
    /// Called by selector actor on its executor.
    ///
    /// - Returns: The next reply, or `nil` if shutdown.
    public func next() async -> IO.Event.Registration.Reply? {
        enum Action {
            case returnNil
            case returnReply(IO.Event.Registration.Reply)
            case suspend
        }

        return await withCheckedContinuation { continuation in
            let action: Action = state.withLock { state in
                if state.isShutdown { return .returnNil }
                if let reply = state.replies.first {
                    state.replies.removeFirst()
                    return .returnReply(reply)
                }
                state.continuation = continuation
                return .suspend
            }
            // Resume OUTSIDE lock
            switch action {
            case .returnNil: continuation.resume(returning: nil)
            case .returnReply(let reply): continuation.resume(returning: reply)
            case .suspend: break
            }
        }
    }

    /// Signal shutdown.
    ///
    /// After this call:
    /// - Any pending `next()` returns `nil`
    /// - Future `next()` calls return `nil` immediately
    /// - Future `push()` calls are silently ignored
    public func shutdown() {
        // Extract continuation inside lock, resume OUTSIDE lock
        let continuationToResume: CheckedContinuation<IO.Event.Registration.Reply?, Never>? = state.withLock { state in
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
