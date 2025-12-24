//
//  IO.Blocking.Threads.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 24/12/2025.
//

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
        public init(_ options: Options = .init()) {
            self.runtime = Runtime(options: options)
        }

        deinit {
            // If not properly shut down, force shutdown synchronously
            if runtime.isStarted && !runtime.state.isShutdown {
                runtime.state.lock.withLock {
                    runtime.state.isShutdown = true
                }
                runtime.state.lock.broadcast()
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
            guaranteesRunOnceEnqueued: true
        )
    }
}

// MARK: - runBoxed (Two-Stage Acceptance/Completion)

extension IO.Blocking.Threads {
    /// Execute a boxed operation using two-stage acceptance/completion.
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
    /// ## Invariants
    /// - No helper `Task {}` spawned inside lane machinery
    /// - Exactly-once resume for all continuations
    /// - Cancel-wait-but-drain-completion: cancelled callers don't leak boxes
    public func runBoxed(
        deadline: IO.Blocking.Deadline?,
        _ operation: @Sendable @escaping () -> UnsafeMutableRawPointer
    ) async throws(IO.Blocking.Failure) -> UnsafeMutableRawPointer {
        // Stage 1: Acceptance
        let ticket = try await awaitAcceptance(deadline: deadline, operation: operation)

        // Stage 2: Completion
        return try await awaitCompletion(ticket: ticket)
    }

    /// Stage 1: Wait for acceptance (may suspend if queue is full).
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

        do {
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Ticket, any Error>) in
                    state.lock.lock()

                    // Check shutdown
                    if state.isShutdown {
                        state.lock.unlock()
                        continuation.resume(throwing: IO.Blocking.Failure.shutdown)
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
                        state.lock.signal()
                        state.lock.unlock()
                        continuation.resume(returning: ticket)
                        return
                    }

                    // Queue is full - handle based on backpressure policy
                    switch options.backpressure {
                    case .throw:
                        state.lock.unlock()
                        continuation.resume(throwing: IO.Blocking.Failure.queueFull)

                    case .suspend:
                        // Register acceptance waiter
                        let waiter = Acceptance.Waiter(
                            ticket: ticket,
                            deadline: deadline,
                            operation: operation,
                            continuation: continuation,
                            resumed: false
                        )
                        state.acceptanceWaiters.append(waiter)
                        state.lock.unlock()
                    }
                }
            } onCancel: {
                // Remove from acceptance waiters if still there
                state.lock.lock()
                _ = state.removeAcceptanceWaiter(ticket: ticket)
                state.lock.unlock()
            }
        } catch let error as IO.Blocking.Failure {
            throw error
        } catch {
            // Should never happen - we only throw Failure
            throw .cancelled
        }
    }

    /// Stage 2: Wait for job completion (cancellable but drains).
    private func awaitCompletion(ticket: Ticket) async throws(IO.Blocking.Failure) -> UnsafeMutableRawPointer {
        let state = runtime.state

        // Check cancellation - but we still need to handle draining
        if Task.isCancelled {
            state.lock.lock()
            // Check if completion already arrived - if so, destroy it
            if let box = state.completions.removeValue(forKey: ticket) {
                state.lock.unlock()
                Box.destroy(box)
            } else {
                // No completion yet - mark ticket as abandoned
                // The completion will be destroyed when it arrives
                state.abandonedTickets.insert(ticket)
                state.lock.unlock()
            }
            throw .cancelled
        }

        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<UnsafeMutableRawPointer, Never>) in
                state.lock.lock()

                // Check if completion already available
                if let box = state.completions.removeValue(forKey: ticket) {
                    state.lock.unlock()
                    continuation.resume(returning: box)
                    return
                }

                // Register completion waiter
                state.completionWaiters[ticket] = Completion.Waiter(
                    continuation: continuation,
                    abandoned: false,
                    resumed: false
                )
                state.lock.unlock()
            }
        } onCancel: {
            state.lock.lock()
            // Check if completion arrived while we were waiting
            if let box = state.completions.removeValue(forKey: ticket) {
                state.lock.unlock()
                Box.destroy(box)
                return
            }

            // Mark waiter as abandoned (waiter was registered)
            if var waiter = state.completionWaiters[ticket] {
                waiter.abandoned = true
                state.completionWaiters[ticket] = waiter
            }
            state.lock.unlock()
        }
    }

    /// Shutdown the lane (Mode B: accepted jobs always run).
    ///
    /// ## Shutdown Sequence
    /// 1. Set shutdown flag
    /// 2. Resume all acceptance waiters with `.shutdown`
    /// 3. Signal workers
    /// 4. Wait for queue to drain and in-flight jobs to complete
    /// 5. Join worker threads
    public func shutdown() async {
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
        waitersToResume = state.acceptanceWaiters
        state.acceptanceWaiters.removeAll()

        state.lock.unlock()

        // Wake all workers
        state.lock.broadcast()

        // Resume acceptance waiters with shutdown (outside lock)
        for var waiter in waitersToResume {
            if !waiter.resumed {
                waiter.resumeThrowing(.shutdown)
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
                    state.lock.wait()
                }
                state.lock.unlock()
                continuation.resume()
            }
        }

        // Join all threads
        runtime.joinAllThreads()
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
                try await impl.runBoxed(deadline: deadline, operation)
            },
            shutdown: { await impl.shutdown() }
        )
    }
}
