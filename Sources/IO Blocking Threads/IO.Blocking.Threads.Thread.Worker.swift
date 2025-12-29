//
//  IO.Blocking.Threads.Thread.Worker.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 24/12/2025.
//

extension IO.Blocking.Threads.Thread {
    /// Worker loop running on a dedicated OS thread.
    ///
    /// ## Design (Unified Single-Stage)
    /// Each worker:
    /// 1. Waits for jobs on the shared queue (via condition variable)
    /// 2. Executes jobs to completion
    /// 3. Calls `job.context.tryComplete()` directly (no dictionary lookup)
    /// 4. Promotes acceptance waiters when capacity available
    /// 5. Exits when shutdown flag is set and queue is drained
    struct Worker {
        let id: Int
        let state: State
    }
}

extension IO.Blocking.Threads.Thread.Worker {
    /// The main worker loop.
    ///
    /// Runs until shutdown is signaled and all jobs are drained.
    func run() {
        while true {
            // Acquire lock and wait for job
            state.lock.lock()

            // Wait for job or shutdown
            while state.queue.isEmpty && !state.isShutdown {
                state.lock.waitWorker()
            }

            // Check for exit condition: shutdown + empty queue
            if state.isShutdown && state.queue.isEmpty {
                state.lock.unlock()
                return
            }

            // Dequeue job
            guard let job = state.queue.dequeue() else {
                state.lock.unlock()
                continue
            }

            state.inFlightCount += 1

            // Promote acceptance waiters now that we have capacity
            // With unified design, this enqueues jobs directly -
            // contexts are completed by workers, not here
            state.promoteAcceptanceWaiters()

            state.lock.unlock()

            // Execute job outside lock
            // Job.run() calls context.tryComplete() directly
            job.run()

            // Mark completion
            state.lock.lock()
            state.inFlightCount -= 1
            // If shutdown and queue empty and no in-flight, signal shutdown waiter
            if state.isShutdown && state.queue.isEmpty && state.inFlightCount == 0 {
                state.lock.broadcastWorker()
            }
            state.lock.unlock()
        }
    }
}
