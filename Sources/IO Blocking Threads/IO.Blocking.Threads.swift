//
//  IO.Blocking.Threads.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 24/12/2025.
//

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
    /// - `guaranteesRunOnceEnqueued`: true
    ///
    /// ## Backpressure
    /// - `.suspend`: Callers wait for queue capacity (bounded by deadline).
    /// - `.throw`: Callers receive `.queueFull` immediately if queue is full.
    public final class Threads: Sendable {
        private let runtime: Runtime

        /// Creates a Threads lane with the given options.
        init(_ options: Options = .init()) {
            self.runtime = Runtime(options: options)
        }

        deinit {
            // If not properly shut down, force shutdown synchronously
            if runtime.isStarted && !runtime.state.isShutdown {
                runtime.state.lock.withLock {
                    runtime.state.isShutdown = true
                }
                runtime.state.lock.broadcastAll()
                runtime.joinAll()
            }
        }
    }
}

// MARK: - Capabilities

extension IO.Blocking.Threads {
    var capabilities: IO.Blocking.Capabilities {
        IO.Blocking.Capabilities(
            executesOnDedicatedThreads: true,
            guaranteesRunOnceEnqueued: true
        )
    }
}

// MARK: - Run Accessor

extension IO.Blocking.Threads {
    /// Accessor for running operations on this lane.
    var run: Run { Run(self) }
}

// MARK: - Threads.Run

extension IO.Blocking.Threads {
    /// Accessor for running operations on this lane.
    struct Run {
        private let threads: IO.Blocking.Threads

        fileprivate init(_ threads: IO.Blocking.Threads) {
            self.threads = threads
        }

        /// Executes a boxed operation using two-stage acceptance/completion.
        ///
        /// ## Design
        /// 1. **Acceptance stage**: Enqueue job and get a ticket
        /// 2. **Completion stage**: Wait for job completion using the ticket
        ///
        /// ## Cancellation Semantics
        /// - Cancellation before acceptance: throw `.cancelled`, no job runs
        /// - Cancellation while waiting for acceptance: throw `.cancelled`, no job runs
        /// - Cancellation after acceptance: job runs to completion, result is drained, throw `.cancelled`
        ///
        // Invariants:
        // - No helper Task{} spawned inside lane machinery
        // - Exactly-once resume for all continuations
        // - Cancel-wait-but-drain-completion: cancelled callers don't leak boxes
        func boxed(
            deadline: IO.Blocking.Deadline?,
            _ operation: @Sendable @escaping () -> UnsafeMutableRawPointer
        ) async throws(IO.Blocking.Failure) -> UnsafeMutableRawPointer {
            // Stage 1: Acceptance
            let ticket = try await threads.awaitAcceptance(deadline: deadline, operation: operation)

            // Stage 2: Completion
            let boxPointer = try await threads.awaitCompletion(ticket: ticket)
            return boxPointer.raw
        }
    }
}

// MARK: - Internal Acceptance/Completion

extension IO.Blocking.Threads {
    /// Stage 1: Waits for acceptance (may suspend if queue is full).
    // Typed Throws via Result:
    // Uses withCheckedContinuation with Result<Ticket, Failure> instead of
    // withCheckedThrowingContinuation to preserve typed throws throughout.
    // No any Error appears in this code path.
    private func awaitAcceptance(
        deadline: IO.Blocking.Deadline?,
        operation: @Sendable @escaping () -> UnsafeMutableRawPointer
    ) async throws(IO.Blocking.Failure) -> Ticket {
        // Check cancellation upfront
        if Task.isCancelled {
            throw .cancelled
        }

        // Lazy start workers
        runtime.startIfNeeded()

        let state = runtime.state
        let options = runtime.options

        // Generate ticket under lock
        let ticket: Ticket = state.lock.withLock { state.makeTicket() }

        let outcome: Acceptance.Waiter.Outcome = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: Acceptance.Waiter.Continuation) in
                state.lock.lock()

                // Check shutdown
                if state.isShutdown {
                    state.lock.unlock()
                    continuation.resume(returning: .failure(.shutdown))
                    return
                }

                // Create the job with completion callback
                let job = Job.Instance(
                    ticket: ticket,
                    operation: operation
                ) { [weak state] completedTicket, box in
                    state?.complete(ticket: completedTicket, box: box)
                }

                // Try to enqueue directly
                if state.tryEnqueue(job) {
                    state.lock.worker.signal()
                    state.lock.unlock()
                    continuation.resume(returning: .success(ticket))
                    return
                }

                // Queue is full - invoke behavior to decide
                let queueFullContext = IO.Backpressure.Lane.QueueFull.Context(
                    queueCount: state.queue.count,
                    queueCapacity: state.queue.capacity,
                    deadline: deadline,
                    acceptanceWaitersCount: state.acceptanceWaiters.count,
                    acceptanceWaitersCapacity: state.acceptanceWaiters.capacity
                )

                switch options.policy.behavior.onQueueFull(queueFullContext) {
                case .fail(let failure):
                    state.lock.unlock()
                    continuation.resume(returning: .failure(failure))

                case .wait:
                    // Register acceptance waiter
                    let waiter = Acceptance.Waiter(
                        ticket: ticket,
                        deadline: deadline,
                        operation: operation,
                        continuation: continuation,
                        resumed: false
                    )
                    // Bounded queue - invoke overflow behavior if full
                    guard state.acceptanceWaiters.enqueue(waiter) else {
                        let overflowContext = IO.Backpressure.Lane.AcceptanceOverflow.Context(
                            waitersCount: state.acceptanceWaiters.count,
                            waitersCapacity: state.acceptanceWaiters.capacity,
                            queueCount: state.queue.count,
                            queueCapacity: state.queue.capacity
                        )
                        let error = options.policy.behavior.onAcceptanceOverflow(overflowContext)
                        state.lock.unlock()
                        continuation.resume(returning: .failure(error))
                        return
                    }
                    // Signal deadline manager if waiter has a deadline
                    if deadline != nil {
                        state.lock.deadline.signal()
                    }
                    state.lock.unlock()
                }
            }
        } onCancel: {
            // Remove from acceptance waiters if still there
            state.lock.lock()
            _ = state.removeAcceptanceWaiter(ticket: ticket)
            state.lock.unlock()
        }

        // Unwrap Result - typed throws preserved
        switch outcome {
        case .success(let ticket):
            return ticket
        case .failure(let error):
            throw error
        }
    }

    /// Stage 2: Waits for job completion (cancellable, immediate unblock on cancel).
    // Single-Resumer Authority:
    // Exactly one path resumes the continuation:
    // - Cancellation path: removes waiter (if registered) and resumes with .cancelled
    // - Completion path: removes waiter and resumes with box
    // Both paths remove the waiter under lock before resuming, so only one can succeed.
    // The abandonedTickets set ensures resource cleanup when no waiter will consume the box.
    //
    // Typed Throws via Result:
    // Uses withCheckedContinuation with Result<BoxPointer, Failure> instead of
    // withCheckedThrowingContinuation to preserve typed throws throughout.
    // No any Error appears in this code path.
    private func awaitCompletion(ticket: Ticket) async throws(IO.Blocking.Failure) -> IO.Blocking.Box.Pointer {
        let state = runtime.state

        let outcome: Completion.Waiter.Outcome = await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: Completion.Waiter.Continuation) in
                state.lock.lock()
                defer { state.lock.unlock() }

                // Check if completion already available
                if let box = state.completions.removeValue(forKey: ticket) {
                    cont.resume(returning: .success(IO.Blocking.Box.Pointer(box)))
                    return
                }

                // Check if already cancelled before registering waiter
                if Task.isCancelled {
                    state.abandonedTickets.insert(ticket)
                    cont.resume(returning: .failure(.cancelled))
                    return
                }

                // Register waiter - cancellation or completion will resume it
                state.completionWaiters[ticket] = Completion.Waiter(continuation: cont)
            }
        } onCancel: {
            state.lock.lock()
            defer { state.lock.unlock() }

            // If completion already arrived, destroy it
            if let box = state.completions.removeValue(forKey: ticket) {
                state.abandonedTickets.insert(ticket)
                state.destroyBox(ticket: ticket, box: box)
                return
            }

            // If waiter registered, we own resumption - remove and resume with error
            if var waiter = state.completionWaiters.removeValue(forKey: ticket) {
                state.abandonedTickets.insert(ticket)
                waiter.resume(with: .failure(.cancelled))
                return
            }

            // Waiter not yet registered - mark abandoned for later
            state.abandonedTickets.insert(ticket)
        }

        // Unwrap Result - typed throws preserved
        switch outcome {
        case .success(let boxPointer):
            return boxPointer
        case .failure(let error):
            throw error
        }
    }

    /// Shuts down the lane. Accepted jobs always run to completion.
    ///
    /// ## Shutdown Sequence
    /// 1. Sets shutdown flag
    /// 2. Resumes all acceptance waiters with `.shutdown`
    /// 3. Signals workers
    /// 4. Waits for queue to drain and in-flight jobs to complete
    /// 5. Joins worker threads
    func shutdown() async {
        guard runtime.isStarted else { return }

        let state = runtime.state

        // Collect acceptance waiters to resume
        var waitersToResume: [Acceptance.Waiter] = []

        state.lock.lock()
        guard !state.isShutdown else {
            state.lock.unlock()
            return
        }
        state.isShutdown = true

        // Drain acceptance waiters
        waitersToResume = state.acceptanceWaiters.drainAll()

        state.lock.unlock()

        // Wake all workers and deadline manager
        state.lock.broadcastAll()

        // Resume acceptance waiters with shutdown (outside lock)
        for var waiter in waitersToResume {
            if !waiter.resumed {
                waiter.resume(with: .failure(.shutdown))
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
        runtime.joinAll()
    }
}

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
                ) async throws(IO.Blocking.Failure) -> UnsafeMutableRawPointer in
                try await impl.run.boxed(deadline: deadline, operation)
            },
            shutdown: { await impl.shutdown() }
        )
    }
}
