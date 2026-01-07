//
//  IO.Blocking.Threads.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 24/12/2025.
//

import Buffer
import Synchronization

// MARK: - Future: Platform Executor Adaptation
// This lane may be backed by a platform executor in the future.
// Do not assume Threads is the only Lane implementation.

extension IO.Blocking {
    /// A lane implementation backed by dedicated OS threads.
    ///
    /// ## Design
    /// - Spawns dedicated OS threads that do not interfere with Swift's cooperative pool.
    /// - Bounded queue with configurable backpressure policy.
    /// - Jobs run to completion once enqueued (mutation semantics guaranteed).
    ///
    /// ## Capabilities
    /// - `executesOnDedicatedThreads`: true
    /// - `executionSemantics`: `.guaranteed`
    ///
    /// ## Backpressure
    /// - `.wait`: Callers wait for queue capacity (bounded by deadline).
    /// - `.failFast`: Callers receive `.queueFull` immediately if queue is full.
    public final class Threads: Sendable {
        private let runtime: Runtime

        /// Creates a Threads lane with the given options.
        public init(_ options: Options = .init()) {
            self.runtime = Runtime(options: options)
        }

        deinit {
            // If not properly shut down, force shutdown synchronously
            if runtime.isStarted && !runtime.state.isShutdown {
                runtime.state.lock.withLock {
                    runtime.state.isShutdown = true
                }
                runtime.state.lock.broadcast.all()
                runtime.joinAllThreads()
            }
        }
    }
}

// MARK: - Capabilities

extension IO.Blocking.Threads {
    public var capabilities: IO.Blocking.Capabilities {
        IO.Blocking.Capabilities(
            executesOnDedicatedThreads: true,
            executionSemantics: .guaranteed
        )
    }
}

// MARK: - runBoxed (Unified Single-Stage)

extension IO.Blocking.Threads {
    /// Execute a boxed operation using unified single-stage completion.
    ///
    /// ## Design
    /// Single continuation for the entire operation. The context is bundled with
    /// the job, eliminating dictionary lookups on the completion path.
    ///
    /// ## Flow
    /// 1. Create context with continuation
    /// 2. Create job with bundled context
    /// 3. Enqueue job (or wait in acceptance queue)
    /// 4. Worker executes and calls `context.complete()` directly
    ///
    /// ## Cancellation Semantics
    /// - All cancellation paths use `context.cancel()`
    /// - Atomic state ensures exactly-once resumption
    /// - If job completes after cancellation, box is destroyed
    ///
    /// ## Exactly-Once Guarantees
    /// Every path completes the context exactly once:
    /// - Success: worker calls `context.complete(box)`
    /// - Cancel: handler calls `context.cancel()`
    /// - Failure: error path calls `context.fail(error)`
    public func runBoxed(
        deadline: IO.Blocking.Deadline?,
        _ operation: @Sendable @escaping () -> UnsafeMutableRawPointer
    ) async throws(IO.Lifecycle.Error<IO.Blocking.Lane.Error>) -> UnsafeMutableRawPointer {
        // Check cancellation upfront
        if Task.isCancelled {
            throw .cancellation
        }

        // Lazy start workers
        runtime.start.ifNeeded()

        let state = runtime.state
        let options = runtime.options
        let onTransition = options.onStateTransition

        // Generate ticket (lock-free atomic)
        let ticket: IO.Blocking.Ticket = state.makeTicket()

        // Shared context reference for cancellation handler
        // Uses Mutex to safely share between continuation body and onCancel
        let contextHolder = Mutex<Completion.Context?>(nil)

        // Use non-throwing continuation with Result to eliminate `any Error`
        let result: Completion.Result = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Completion.Result, Never>) in
                // Create context with continuation
                let context = Completion.Context(continuation: continuation)

                // Store in holder for cancellation handler access
                contextHolder.withLock { $0 = context }

                // Check cancellation inside continuation (handles race with onCancel)
                if Task.isCancelled {
                    _ = context.fail(.cancellation)
                    return
                }

                // Create job with bundled context
                var job = Job.Instance(
                    ticket: ticket,
                    context: context,
                    operation: operation
                )

                state.lock.lock()

                // Check shutdown
                if state.isShutdown {
                    state.lock.unlock()
                    _ = context.fail(.shutdownInProgress)
                    return
                }

                // Capture state before enqueue for transition detection
                let wasEmpty = state.queue.isEmpty
                let wasFull = state.queue.isFull

                // Try to enqueue directly with transition-based wakeup
                if state.tryEnqueue(job) {
                    // Wake all sleeping workers if queue transitioned empty→non-empty
                    state.wakeSleepersIfNeeded(didBecomeNonEmpty: wasEmpty)

                    // Capture saturation state before unlock (needed for transition callback)
                    let becameSaturated = !wasFull && state.queue.isFull
                    state.lock.unlock()

                    // Deliver state transitions out-of-lock (only if callback is set)
                    if let onTransition = onTransition {
                        if wasEmpty {
                            onTransition(.becameNonEmpty)
                        }
                        if becameSaturated {
                            onTransition(.becameSaturated)
                        }
                    }

                    // Job enqueued - worker will complete via context
                    return
                }

                // Queue is full - handle based on backpressure policy
                switch options.strategy {
                case .failFast:
                    state.counters.incrementFailFast()  // Lock-free atomic
                    state.lock.unlock()
                    _ = context.fail(.failure(.queueFull))

                case .wait:
                    // Set acceptance timestamp for wait time tracking
                    job.acceptanceTimestamp = IO.Blocking.Deadline.now

                    // Register acceptance waiter (job already has context)
                    let waiter = Acceptance.Waiter(
                        job: job,
                        deadline: deadline,
                        resumed: false
                    )
                    // Bounded queue - fail fast if full
                    guard state.acceptanceWaiters.enqueue(waiter) else {
                        state.counters.incrementOverloaded()  // Lock-free atomic
                        state.lock.unlock()
                        _ = context.fail(.failure(.overloaded))
                        return
                    }
                    // Signal deadline manager if waiter has a deadline
                    if deadline != nil {
                        state.lock.deadline.signal()
                    }
                    state.lock.unlock()
                // Waiter registered - will be promoted when capacity available
                }
            }
        } onCancel: {
            // Try to cancel via context
            // May fail if already completed/failed - that's fine
            let didCancel = contextHolder.withLock { context -> Bool in
                if let context = context {
                    return context.cancel(.cancellation)
                }
                return false
            }

            // Increment cancelled counter if we actually cancelled
            if didCancel {
                state.counters.incrementCancelled()  // Lock-free atomic
            }

            // Also try to mark acceptance waiter as resumed
            // This prevents it from being promoted after cancellation
            state.lock.lock()
            if let waiter = state.removeAcceptanceWaiter(ticket: ticket) {
                // Waiter found and marked - context.cancel() above handles resumption
                // The waiter's job won't be enqueued during promotion
                _ = waiter  // Suppress unused warning
            }
            state.lock.unlock()
        }

        // Convert typed Result to typed throws
        switch result {
        case .success(let boxPointer):
            return boxPointer.raw
        case .failure(let error):
            throw error
        }
    }

    /// Shutdown the lane (Mode B: accepted jobs always run).
    ///
    /// ## Shutdown Sequence
    /// 1. Set shutdown flag
    /// 2. Fail all acceptance waiters via their contexts
    /// 3. Signal workers
    /// 4. Wait for queue to drain and in-flight jobs to complete
    /// 5. Join worker threads
    public func shutdown() async {
        guard runtime.isStarted else { return }

        let state = runtime.state

        // Collect acceptance waiters to fail
        var waitersToFail: [Acceptance.Waiter] = []

        state.lock.lock()
        guard !state.isShutdown else {
            state.lock.unlock()
            return
        }
        state.isShutdown = true

        // Drain acceptance waiters
        waitersToFail = state.acceptanceWaiters.drain()

        state.lock.unlock()

        // Wake all workers and deadline manager
        state.lock.broadcast.all()

        // Fail acceptance waiters via their contexts (outside lock)
        for waiter in waitersToFail {
            if !waiter.resumed {
                // Use context's atomic tryFail - exactly-once guaranteed
                _ = waiter.job.context.fail(.shutdownInProgress)
            }
        }

        // Wait for in-flight jobs to complete
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            state.lock.lock()
            let done = state.inFlightCount == 0 && state.queue.isEmpty
            state.lock.unlock()

            if done {
                continuation.resume()
            } else {
                // Use condvar wait instead of polling
                state.lock.lock()
                while !(state.inFlightCount == 0 && state.queue.isEmpty) {
                    state.lock.worker.wait()
                }
                state.lock.unlock()
                continuation.resume()
            }
        }

        // Join all threads
        runtime.joinAllThreads()
    }
}

// MARK: - Metrics

extension IO.Blocking.Threads {
    /// Returns current metrics snapshot.
    ///
    /// All values are read atomically under the runtime lock,
    /// ensuring a consistent snapshot.
    ///
    /// ## Usage
    /// Call periodically to monitor lane health:
    /// ```swift
    /// let m = lane.metrics()
    /// print("Queue depth: \(m.queueDepth)")
    /// print("Executing: \(m.executingCount)")
    /// ```
    public func metrics() -> Metrics {
        let state = runtime.state
        state.lock.lock()
        defer { state.lock.unlock() }

        return Metrics(
            queueDepth: state.queue.count,
            acceptanceWaitersDepth: state.acceptanceWaiters.count,
            executingCount: state.inFlightCount,
            sleepingWorkers: state.lock.worker.waiterCount,
            enqueuedTotal: state.counters.enqueued,
            startedTotal: state.counters.started,
            completedTotal: state.counters.completed,
            acceptancePromotedTotal: state.counters.acceptancePromoted,
            acceptanceTimeoutTotal: state.counters.acceptanceTimeout,
            failFastTotal: state.counters.failFast,
            overloadedTotal: state.counters.overloaded,
            cancelledTotal: state.counters.cancelled,
            enqueueToStart: state.enqueueToStartAggregate.snapshot(),
            execution: state.executionAggregate.snapshot(),
            acceptanceWait: state.acceptanceWaitAggregate.snapshot()
        )
    }
}

// MARK: - Test Observability

extension IO.Blocking.Threads {
    /// Returns a snapshot of internal state under the lock.
    /// Use for test assertions only.
    public func debugSnapshot() -> DebugSnapshot {
        runtime.state.lock.lock()
        defer { runtime.state.lock.unlock() }
        return DebugSnapshot(
            sleepers: runtime.state.lock.worker.waiterCount,
            queueIsEmpty: runtime.state.queue.isEmpty,
            queueCount: runtime.state.queue.count,
            inFlightCount: runtime.state.inFlightCount,
            isShutdown: runtime.state.isShutdown
        )
    }

    /// Number of worker threads configured.
    public var workerCount: Int {
        Int(runtime.options.workers)
    }
}

// MARK: - Test-Only Enqueue API

#if IO_TESTING
extension IO.Blocking.Threads {
    /// Test-only: Execute with a callback when enqueued.
    ///
    /// The callback is invoked outside the lock, immediately after successful enqueue.
    /// This allows deterministic testing of queue ordering without polling.
    ///
    /// ## Usage
    /// ```swift
    /// let enqueued = Signal()
    /// let task = Task {
    ///     try await threads.runBoxedWithEnqueueCallback(
    ///         deadline: nil,
    ///         onEnqueued: { enqueued.signal() }
    ///     ) { ... }
    /// }
    /// enqueued.wait()  // Now job is definitely in queue
    /// ```
    ///
    /// ## Note
    /// The callback is only invoked for direct enqueue success. Jobs that go through
    /// acceptance waiting (backpressure `.wait` with full queue) do not invoke the callback
    /// until promoted to the main queue.
    public func runBoxedWithEnqueueCallback(
        deadline: IO.Blocking.Deadline?,
        onEnqueued: @Sendable @escaping () -> Void,
        _ operation: @Sendable @escaping () -> UnsafeMutableRawPointer
    ) async throws(IO.Lifecycle.Error<IO.Blocking.Lane.Error>) -> UnsafeMutableRawPointer {
        // Check cancellation upfront
        if Task.isCancelled {
            throw .cancellation
        }

        // Lazy start workers
        runtime.start.ifNeeded()

        let state = runtime.state
        let options = runtime.options
        let onTransition = options.onStateTransition

        // Generate ticket (lock-free atomic)
        let ticket: IO.Blocking.Ticket = state.makeTicket()

        // Shared context reference for cancellation handler
        let contextHolder = Mutex<Completion.Context?>(nil)

        // Use non-throwing continuation with Result
        let result: Completion.Result = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Completion.Result, Never>) in
                // Create context with continuation
                let context = Completion.Context(continuation: continuation)

                // Store in holder for cancellation handler access
                contextHolder.withLock { $0 = context }

                // Check cancellation inside continuation
                if Task.isCancelled {
                    _ = context.fail(.cancellation)
                    return
                }

                // Create job with bundled context
                var job = Job.Instance(
                    ticket: ticket,
                    context: context,
                    operation: operation
                )

                state.lock.lock()

                // Check shutdown
                if state.isShutdown {
                    state.lock.unlock()
                    _ = context.fail(.shutdownInProgress)
                    return
                }

                // Capture state before enqueue for transition detection
                let wasEmpty = state.queue.isEmpty
                let wasFull = state.queue.isFull

                // Try to enqueue directly
                if state.tryEnqueue(job) {
                    // Wake sleeping workers if needed
                    state.wakeSleepersIfNeeded(didBecomeNonEmpty: wasEmpty)

                    // Capture saturation state before unlock (needed for transition callback)
                    let becameSaturated = !wasFull && state.queue.isFull
                    state.lock.unlock()

                    // Deliver state transitions out-of-lock (only if callback is set)
                    if let onTransition = onTransition {
                        if wasEmpty {
                            onTransition(.becameNonEmpty)
                        }
                        if becameSaturated {
                            onTransition(.becameSaturated)
                        }
                    }

                    // >>> TEST HOOK: Signal enqueue success <<<
                    onEnqueued()

                    // Job enqueued - worker will complete via context
                    return
                }

                // Queue is full - handle based on backpressure policy
                switch options.strategy {
                case .failFast:
                    state.counters.incrementFailFast()  // Lock-free atomic
                    state.lock.unlock()
                    _ = context.fail(.failure(.queueFull))

                case .wait:
                    // Set acceptance timestamp for wait time tracking
                    job.acceptanceTimestamp = IO.Blocking.Deadline.now

                    // Register acceptance waiter
                    let waiter = Acceptance.Waiter(
                        job: job,
                        deadline: deadline,
                        resumed: false
                    )
                    guard state.acceptanceWaiters.enqueue(waiter) else {
                        state.counters.incrementOverloaded()  // Lock-free atomic
                        state.lock.unlock()
                        _ = context.fail(.failure(.overloaded))
                        return
                    }
                    if deadline != nil {
                        state.lock.deadline.signal()
                    }
                    state.lock.unlock()
                    // Note: onEnqueued NOT called for acceptance waiters
                }
            }
        } onCancel: {
            let didCancel = contextHolder.withLock { context -> Bool in
                if let context = context {
                    return context.cancel(.cancellation)
                }
                return false
            }

            if didCancel {
                state.counters.incrementCancelled()  // Lock-free atomic
            }

            state.lock.lock()
            if let waiter = state.removeAcceptanceWaiter(ticket: ticket) {
                _ = waiter
            }
            state.lock.unlock()
        }

        // Convert Result to typed throws
        switch result {
        case .success(let boxPointer):
            return boxPointer.raw
        case .failure(let error):
            throw error
        }
    }
}
#endif

// MARK: - Lane Factory

extension IO.Blocking.Lane {
    /// Creates a lane backed by dedicated OS threads.
    public static func threads(_ options: IO.Blocking.Threads.Options = .init()) -> Self {
        let impl = IO.Blocking.Threads(options)
        return Self(
            capabilities: impl.capabilities,
            run: {
                (
                    deadline: IO.Blocking.Deadline?,
                    operation: @Sendable @escaping () -> UnsafeMutableRawPointer
                ) async throws(IO.Lifecycle.Error<IO.Blocking.Lane.Error>) -> UnsafeMutableRawPointer in
                try await impl.runBoxed(deadline: deadline, operation)
            },
            shutdown: { await impl.shutdown() }
        )
    }
}
