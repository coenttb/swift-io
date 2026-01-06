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
    /// ## Design (Unified Single-Stage)
    /// Each worker:
    /// 1. Waits for jobs on the shared queue (via condition variable)
    /// 2. Executes jobs to completion
    /// 3. Calls `job.context.complete()` directly (no dictionary lookup)
    /// 4. Promotes acceptance waiters when capacity available
    /// 5. Exits when shutdown flag is set and queue is drained
    struct Worker {
        let id: Int
        let state: Runtime.State
        let scheduling: Scheduling
        let onTransition: (@Sendable (State.Transition) -> Void)?
    }
}

extension IO.Blocking.Threads.Worker {
    /// Maximum jobs to drain per wake cycle.
    /// Amortizes lock operations and reduces sleep/wake frequency.
    private static let drainLimit: Int = 16

    /// The main worker loop.
    ///
    /// ## Design
    /// - Uses `waitTracked()` so Kernel tracks waiter count for signal suppression
    /// - Drains up to `drainLimit` jobs per wake to amortize lock overhead
    /// - Promotes acceptance waiters after each job completes
    ///
    /// Runs until shutdown is signaled and all jobs are drained.
    func run() {
        while true {
            // Acquire lock and wait for job
            state.lock.lock()

            // Wait for job or shutdown using tracked wait
            while state.queue.isEmpty && !state.isShutdown {
                state.lock.worker.waitTracked()
            }

            // Check for exit condition: shutdown + empty queue
            if state.isShutdown && state.queue.isEmpty {
                state.lock.unlock()
                return
            }

            // Drain loop: process up to drainLimit jobs before going back to wait
            var drained = 0
            while drained < Self.drainLimit {
                // Capture state before dequeue for transition detection
                let wasFull = state.queue.isFull

                // Dequeue job based on scheduling policy
                let job: IO.Blocking.Threads.Job.Instance?
                switch scheduling {
                case .fifo:
                    job = state.queue.dequeue()
                case .lifo:
                    job = state.queue.dequeueLast()
                }
                guard let job else {
                    break
                }

                // Detect transitions from dequeue
                var transitions: [IO.Blocking.Threads.State.Transition] = []
                if wasFull {
                    transitions.append(.becameNotSaturated)
                }
                if state.queue.isEmpty {
                    transitions.append(.becameEmpty)
                }

                state.inFlightCount += 1
                state.startedTotal &+= 1

                // Record enqueue-to-start latency
                let startTime = IO.Blocking.Deadline.now
                if let enqueueTime = job.enqueueTimestamp {
                    let latencyNs = startTime.nanosecondsSince(enqueueTime)
                    state.enqueueToStartAggregate.record(latencyNs)
                }

                // Promote acceptance waiters now that we have capacity
                // With unified design, this enqueues jobs directly -
                // contexts are completed by workers, not here
                state.promoteAcceptanceWaiters()

                state.lock.unlock()

                // Deliver state transitions out-of-lock
                if let onTransition = onTransition {
                    for transition in transitions {
                        onTransition(transition)
                    }
                }

                // Execute job outside lock
                // Job.run() calls context.complete() directly
                job.run()

                // Capture end time outside lock
                let endTime = IO.Blocking.Deadline.now

                drained += 1

                // Re-acquire lock for next iteration or completion
                state.lock.lock()
                state.inFlightCount -= 1
                state.completedTotal &+= 1

                // Record execution latency
                let executionNs = endTime.nanosecondsSince(startTime)
                state.executionAggregate.record(executionNs)

                // Check shutdown condition
                if state.isShutdown && state.queue.isEmpty && state.inFlightCount == 0 {
                    state.lock.worker.broadcast()
                    state.lock.unlock()
                    return
                }
            }

            state.lock.unlock()
        }
    }
}
