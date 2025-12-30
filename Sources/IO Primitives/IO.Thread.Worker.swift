//
//  IO.Thread.Worker.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 30/12/2025.
//

import Synchronization

extension IO.Thread {
    /// A managed thread lifecycle abstraction.
    ///
    /// ## Purpose
    /// `Worker` provides a reusable building block for managed thread ownership:
    /// - Exactly-once start (factory construction)
    /// - Stop request signaling
    /// - Exactly-once join (via consuming `join()`)
    ///
    /// ## Layer Boundary
    /// This is a **primitive** - it knows nothing about:
    /// - Job queues
    /// - Deadlines or backpressure
    /// - Lane policies
    /// - Wakeup mechanisms (polling only - no condition variables)
    ///
    /// Higher-level constructs (like `IO.Blocking.Threads.Worker`) compose this
    /// primitive and add their own scheduling semantics.
    ///
    /// ## Lifecycle Protocol
    /// - `stop()` is thread-safe and may be called from any thread.
    /// - `join()` is a consuming terminal operation and must not race with
    ///   other operations on the same Worker value.
    /// - The value is single-owner by construction (`~Copyable`).
    ///
    /// ## Usage
    /// ```swift
    /// var worker = try IO.Thread.Worker.start { token in
    ///     while !token.shouldStop {
    ///         // do work
    ///     }
    /// }
    ///
    /// // Later, signal stop and join
    /// worker.stop()
    /// consume worker.join()
    /// ```
    public struct Worker: ~Copyable, Sendable {
        /// The thread handle, consumed exactly once on join.
        private var handle: Handle

        /// The stop token shared with the running thread.
        private let token: Token

        /// Creates a worker (private - use factory `start`)
        private init(handle: consuming Handle, token: Token) {
            self.handle = handle
            self.token = token
        }
    }
}

// MARK: - Token

extension IO.Thread.Worker {
    /// Stop signaling token passed to the worker body.
    ///
    /// The running thread checks `shouldStop` to know when to exit gracefully.
    /// The owner calls `stop()` on the Worker to signal shutdown.
    ///
    /// ## No Wakeup Mechanism
    /// This is a polling-based token only. There is no condition variable or
    /// event to wake the thread. If you need wakeup semantics, use a higher-level
    /// construct (like `IO.Blocking.Threads.Worker`) that adds synchronization
    /// primitives.
    ///
    /// ## Thread Safety
    /// Uses `Atomic<Bool>` for lock-free signaling. The token is safe to access
    /// from any thread.
    public final class Token: Sendable {
        private let stopped: Atomic<Bool>

        init() {
            self.stopped = Atomic(false)
        }

        /// Check if stop has been requested.
        ///
        /// The worker body should poll this regularly to exit gracefully.
        public var shouldStop: Bool {
            stopped.load(ordering: .acquiring)
        }

        /// Request the worker to stop (internal - use Worker.stop()).
        func requestStop() {
            stopped.store(true, ordering: .releasing)
        }
    }
}

// MARK: - Factory Start

extension IO.Thread.Worker {
    /// Starts a managed worker thread.
    ///
    /// The body receives a `Token` to observe stop requests. When `token.shouldStop`
    /// becomes true, the body should exit promptly.
    ///
    /// ## Lifecycle Guarantees
    /// - The thread is started before this function returns
    /// - The body is invoked exactly once
    /// - On failure, resources are cleaned up (no leaks)
    ///
    /// ## Example
    /// ```swift
    /// var worker = try IO.Thread.Worker.start { token in
    ///     while !token.shouldStop {
    ///         processNextItem()
    ///     }
    /// }
    /// worker.stop()
    /// consume worker.join()
    /// ```
    ///
    /// - Parameter body: Work to run on the thread. Receives a stop token.
    /// - Returns: A started worker with an owned handle.
    /// - Throws: `IO.Thread.Spawn.Error` if thread creation fails.
    public static func start(
        _ body: @escaping @Sendable (Token) -> Void
    ) throws(IO.Thread.Spawn.Error) -> Self {
        let token = Token()

        let handle = try IO.Thread.spawn {
            body(token)
        }

        return Self(handle: handle, token: token)
    }
}

// MARK: - Lifecycle Operations

extension IO.Thread.Worker {
    /// Request the worker to stop.
    ///
    /// Sets the stop flag that the worker body observes via `token.shouldStop`.
    /// This does not forcibly terminate the thread - the body must cooperate
    /// by checking the token and exiting.
    ///
    /// This is idempotent - calling multiple times is safe.
    public func stop() {
        token.requestStop()
    }

    /// Check if stop has been requested.
    public var isStopping: Bool {
        token.shouldStop
    }

    /// Wait for the thread to complete and release resources.
    ///
    /// This is a consuming operation - the worker cannot be used after calling `join()`.
    /// The thread must have exited (typically after observing `token.shouldStop`).
    ///
    /// - Precondition: Must NOT be called from the worker's own thread (deadlock).
    /// - Note: Must be called exactly once. The `~Copyable` constraint enforces this.
    public consuming func join() {
        precondition(
            handle.isCurrentThread == false,
            "IO.Thread.Worker.join() called on the current thread"
        )
        handle.join()
    }
}
