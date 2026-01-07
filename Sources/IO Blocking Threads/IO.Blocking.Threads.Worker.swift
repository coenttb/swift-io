//
//  IO.Blocking.Threads.Worker.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 24/12/2025.
//

import Buffer

extension IO.Blocking.Threads {
    /// Worker loop running on a dedicated OS thread.
    ///
    /// ## Design (Batch Dequeue + Direct Handoff)
    /// Each worker:
    /// 1. Waits for jobs on the shared queue (via condition variable)
    /// 2. Batch-dequeues up to `drainLimit` jobs under ONE lock acquisition
    /// 3. Also takes acceptance waiters directly (direct handoff, skips re-enqueue)
    /// 4. Executes all jobs outside the lock
    /// 5. Updates inFlightCount once per batch
    /// 6. Exits when shutdown flag is set and all work is drained
    ///
    /// ## Performance
    /// - Reduces lock trips from O(k) to O(2) per batch of k jobs
    /// - Direct handoff eliminates acceptance→main queue re-enqueue overhead
    /// - Fast path for single job avoids batch overhead
    struct Worker {
        let id: Int
        let state: Runtime.State
        let scheduling: Scheduling
        let onTransition: (@Sendable (State.Transition) -> Void)?
    }
}

extension IO.Blocking.Threads.Worker {
    /// Maximum jobs to drain per wake cycle.
    @usableFromInline
    static let drainLimit: Int = 16

    /// The main worker loop - optimized for both single-job and batch scenarios.
    @inline(__always)
    func run() {
        // Pre-allocated batch storage (only used when batch > 1)
        var localBatch: [IO.Blocking.Threads.Job.Instance] = []
        localBatch.reserveCapacity(Self.drainLimit)

        while true {
            state.lock.lock()

            // Wait for job, acceptance waiter, or shutdown
            while state.queue.isEmpty && state.acceptanceWaiters.isEmpty && !state.isShutdown {
                state.lock.worker.waitTracked()
            }

            // Exit condition: shutdown + empty queue + no acceptance waiters
            if state.isShutdown && state.queue.isEmpty && state.acceptanceWaiters.isEmpty {
                state.lock.unlock()
                return
            }

            // ========================================
            // FAST PATH: Single job from main queue
            // Optimized for sequential workloads - no batch overhead
            // ========================================
            let firstJob: IO.Blocking.Threads.Job.Instance?
            switch scheduling {
            case .fifo:
                firstJob = state.queue.pop()
            case .lifo:
                firstJob = state.queue.pop.back()
            }

            if let job = firstJob {
                // Check if more jobs available (determines batch vs single path)
                let hasMoreJobs = !state.queue.isEmpty || !state.acceptanceWaiters.isEmpty

                if !hasMoreJobs {
                    // ========================================
                    // SINGLE JOB PATH - NIO-style minimal overhead
                    // Lock-free in-flight tracking eliminates second lock
                    // ========================================
                    state.incrementInFlight()
                    state.counters.incrementStarted()

                    // Transition detection only if callback exists
                    let notifySaturated = onTransition != nil && state.queue.count == state.queue.capacity - 1
                    let notifyEmpty = onTransition != nil && state.queue.isEmpty

                    state.lock.unlock()

                    // Deliver transitions (rare path)
                    if notifySaturated { onTransition!(.becameNotSaturated) }
                    if notifyEmpty { onTransition!(.becameEmpty) }

                    // Execute
                    job.run()

                    // Lock-free completion - no second lock acquisition!
                    state.decrementInFlight()
                    state.counters.incrementCompleted()

                    // Only check shutdown if flag is set (rare path)
                    if state.isShuttingDown {
                        state.lock.lock()
                        if state.isShutdown && state.queue.isEmpty && state.acceptanceWaiters.isEmpty && state.inFlightCount == 0 {
                            state.lock.worker.broadcast()
                            state.lock.unlock()
                            return
                        }
                        state.lock.unlock()
                    }
                    continue
                }

                // ========================================
                // BATCH PATH - amortize lock overhead
                // ========================================
                localBatch.removeAll(keepingCapacity: true)
                localBatch.append(job)

                // Continue filling batch from main queue
                while localBatch.count < Self.drainLimit {
                    let nextJob: IO.Blocking.Threads.Job.Instance?
                    switch scheduling {
                    case .fifo:
                        nextJob = state.queue.pop()
                    case .lifo:
                        nextJob = state.queue.pop.back()
                    }
                    guard let nextJob else { break }
                    localBatch.append(nextJob)
                }

                // Direct handoff from acceptance waiters
                if !state.acceptanceWaiters.isEmpty && localBatch.count < Self.drainLimit {
                    let now = IO.Blocking.Deadline.now
                    while localBatch.count < Self.drainLimit {
                        guard let waiter = state.acceptanceWaiters.dequeue() else { break }

                        if let deadline = waiter.deadline, deadline.hasExpired {
                            _ = waiter.job.context.fail(.timeout)
                            state.counters.incrementAcceptanceTimeout()
                            continue
                        }

                        if let acceptanceTimestamp = waiter.job.acceptanceTimestamp {
                            let waitNs = now.nanosecondsSince(acceptanceTimestamp)
                            state.acceptanceWaitAggregate.record(waitNs)
                        }
                        state.counters.incrementAcceptancePromoted()
                        localBatch.append(waiter.job)
                    }

                    // Promote remaining for other workers
                    if !state.acceptanceWaiters.isEmpty {
                        state.promoteAcceptanceWaiters()
                    }
                }

                state.addInFlight(localBatch.count)
                state.counters.add(started: localBatch.count)
                state.lock.unlock()

                // Execute batch
                for batchJob in localBatch {
                    batchJob.run()
                }

                // Lock-free completion
                state.subtractInFlight(localBatch.count)
                state.counters.add(completed: localBatch.count)

                // Only check shutdown if flag is set
                if state.isShuttingDown {
                    state.lock.lock()
                    if state.isShutdown && state.queue.isEmpty && state.acceptanceWaiters.isEmpty && state.inFlightCount == 0 {
                        state.lock.worker.broadcast()
                        state.lock.unlock()
                        return
                    }
                    state.lock.unlock()
                }

            } else if !state.acceptanceWaiters.isEmpty {
                // ========================================
                // ACCEPTANCE-ONLY PATH
                // Main queue empty, but acceptance waiters pending
                // ========================================
                localBatch.removeAll(keepingCapacity: true)
                let now = IO.Blocking.Deadline.now

                while localBatch.count < Self.drainLimit {
                    guard let waiter = state.acceptanceWaiters.dequeue() else { break }

                    if let deadline = waiter.deadline, deadline.hasExpired {
                        _ = waiter.job.context.fail(.timeout)
                        state.counters.incrementAcceptanceTimeout()
                        continue
                    }

                    if let acceptanceTimestamp = waiter.job.acceptanceTimestamp {
                        let waitNs = now.nanosecondsSince(acceptanceTimestamp)
                        state.acceptanceWaitAggregate.record(waitNs)
                    }
                    state.counters.incrementAcceptancePromoted()
                    localBatch.append(waiter.job)
                }

                if !state.acceptanceWaiters.isEmpty {
                    state.promoteAcceptanceWaiters()
                }

                guard !localBatch.isEmpty else {
                    state.lock.unlock()
                    continue
                }

                state.addInFlight(localBatch.count)
                state.counters.add(started: localBatch.count)
                state.lock.unlock()

                for batchJob in localBatch {
                    batchJob.run()
                }

                // Lock-free completion
                state.subtractInFlight(localBatch.count)
                state.counters.add(completed: localBatch.count)

                // Only check shutdown if flag is set
                if state.isShuttingDown {
                    state.lock.lock()
                    if state.isShutdown && state.queue.isEmpty && state.acceptanceWaiters.isEmpty && state.inFlightCount == 0 {
                        state.lock.worker.broadcast()
                        state.lock.unlock()
                        return
                    }
                    state.lock.unlock()
                }
            } else {
                // Spurious wakeup or shutdown in progress
                state.lock.unlock()
            }
        }
    }
}
