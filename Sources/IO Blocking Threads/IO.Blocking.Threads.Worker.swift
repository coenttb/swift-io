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
        let state: State
    }
}

extension IO.Blocking.Threads.Worker {
    /// Maximum jobs to drain per wake cycle.
    /// Amortizes lock operations and reduces sleep/wake frequency.
    private static let drainLimit: Int = 16

    /// The main worker loop.
    ///
    /// ## Design
    /// - Tracks `sleepers` count to enable signal suppression
    /// - Drains up to `drainLimit` jobs per wake to amortize lock overhead
    /// - Promotes acceptance waiters after each job completes
    ///
    /// Runs until shutdown is signaled and all jobs are drained.
    func run() {
        while true {
            // Acquire lock and wait for job
            state.lock.lock()

            // Wait for job or shutdown, tracking sleepers
            while state.queue.isEmpty && !state.isShutdown {
                state.sleepers += 1
                state.lock.worker.wait()
                state.sleepers -= 1
            }

            // Check for exit condition: shutdown + empty queue
            if state.isShutdown && state.queue.isEmpty {
                state.lock.unlock()
                return
            }

            // Drain loop: process up to drainLimit jobs before going back to wait
            var drained = 0
            while drained < Self.drainLimit {
                // Dequeue job
                guard let job = state.queue.dequeue() else {
                    break
                }

                state.inFlightCount += 1

                // Promote acceptance waiters now that we have capacity
                // With unified design, this enqueues jobs directly -
                // contexts are completed by workers, not here
                state.promoteAcceptanceWaiters()

                state.lock.unlock()

                // Execute job outside lock
                // Job.run() calls context.complete() directly
                job.run()

                drained += 1

                // Re-acquire lock for next iteration or completion
                state.lock.lock()
                state.inFlightCount -= 1

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
