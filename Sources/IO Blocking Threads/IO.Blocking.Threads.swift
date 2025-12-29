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
        public init(_ options: Options = .init()) {
            self.runtime = Runtime(options: options)
        }

        deinit {
            // If not properly shut down, force shutdown synchronously
            if runtime.isStarted && !runtime.state.isShutdown {
                runtime.state.lock.withLock {
                    runtime.state.isShutdown = true
                }
                runtime.state.lock.broadcastAll()
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
    /// - Cancellation before acceptance: throw `.cancellationRequested`, no job runs
    /// - Cancellation while waiting for acceptance: throw `.cancellationRequested`, no job runs
    /// - Cancellation after acceptance: job runs to completion, result is drained, throw `.cancellationRequested`
    ///
    // ## Invariants
    // - No helper `Task {}` spawned inside lane machinery
    // - Exactly-once resume for all continuations
    // - Cancel-wait-but-drain-completion: cancelled callers don't leak boxes
    public func runBoxed(
        deadline: IO.Blocking.Deadline?,
        _ operation: @Sendable @escaping () -> UnsafeMutableRawPointer
    ) async throws(IO.Blocking.Failure) -> UnsafeMutableRawPointer {
        // Stage 1: Acceptance
        let ticket = try await awaitAcceptance(deadline: deadline, operation: operation)

        // Stage 2: Completion
        let boxPointer = try await awaitCompletion(ticket: ticket)
        return boxPointer.raw
    }

    /// Stage 1: Wait for acceptance (may suspend if queue is full).
    private func awaitAcceptance(
        deadline: IO.Blocking.Deadline?,
        operation: @Sendable @escaping () -> UnsafeMutableRawPointer
    ) async throws(IO.Blocking.Failure) -> Ticket {
        // Check cancellation upfront
        if Task.isCancelled {
            throw .cancellationRequested
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
                        state.lock.signalWorker()
                        state.lock.unlock()
                        continuation.resume(returning: ticket)
                        return
                    }

                    // Queue is full - handle based on backpressure policy
                    switch options.strategy {
                    case .failFast:
                        state.lock.unlock()
                        continuation.resume(throwing: IO.Blocking.Failure.queueFull)

                    case .wait:
                        // Register acceptance waiter
                        let waiter = Acceptance.Waiter(
                            ticket: ticket,
                            deadline: deadline,
                            operation: operation,
                            continuation: continuation,
                            resumed: false
                        )
                        // Bounded queue - fail fast if full
                        guard state.acceptanceWaiters.enqueue(waiter) else {
                            state.lock.unlock()
                            continuation.resume(throwing: IO.Blocking.Failure.overloaded)
                            return
                        }
                        // Signal deadline manager if waiter has a deadline
                        if deadline != nil {
                            state.lock.signalDeadline()
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
        } catch let error as IO.Blocking.Failure {
            throw error
        } catch {
            // Should never happen - we only throw Failure
            throw .cancellationRequested
        }
    }

    /// Stage 2: Wait for job completion (cancellable, immediate unblock on cancel).
    ///
    /// Uses `any Error` at the continuation boundary due to Swift stdlib limitations,
    /// but catches and maps to `IO.Blocking.Failure` to preserve typed throws.
    private func awaitCompletion(ticket: Ticket) async throws(IO.Blocking.Failure) -> IO.Blocking.Box.Pointer {
        // ## Single-Resumer Authority
        // Exactly one path resumes the continuation:
        // - Cancellation path: removes waiter (if registered) and resumes with `.cancelled`
        // - Completion path: removes waiter and resumes with box
        //
        // Both paths remove the waiter under lock before resuming, so only one can succeed.
        // The `abandonedTickets` set ensures resource cleanup when no waiter will consume the box.
        //
        // The `Box.Pointer` wrapper provides `@unchecked Sendable` capability at the FFI boundary.
        let state = runtime.state

        do {
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (cont: CheckedContinuation<IO.Blocking.Box.Pointer, any Error>) in
                    state.lock.lock()
                    defer { state.lock.unlock() }

                    // Check if completion already available
                    if let box = state.completions.removeValue(forKey: ticket) {
                        cont.resume(returning: IO.Blocking.Box.Pointer(box))
                        return
                    }

                    // Check if already cancelled before registering waiter
                    if Task.isCancelled {
                        state.abandonedTickets.insert(ticket)
                        cont.resume(throwing: IO.Blocking.Failure.cancellationRequested)
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
                    waiter.resumeThrowing(.cancellationRequested)
                    return
                }

                // Waiter not yet registered - mark abandoned for later
                state.abandonedTickets.insert(ticket)
            }
        } catch {
            // Map any Error back to IO.Blocking.Failure
            if let failure = error as? IO.Blocking.Failure {
                throw failure
            }

            #if DEBUG
            preconditionFailure("Unexpected error type: \(type(of: error)). Only IO.Blocking.Failure is permitted.")
            #else
            throw .internalInvariantViolation
            #endif
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
        waitersToResume = state.acceptanceWaiters.drainAll()

        state.lock.unlock()

        // Wake all workers and deadline manager
        state.lock.broadcastAll()

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
                    state.lock.waitWorker()
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
