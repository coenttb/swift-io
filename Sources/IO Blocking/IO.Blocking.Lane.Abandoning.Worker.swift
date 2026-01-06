//
//  IO.Blocking.Lane.Abandoning.Worker.swift
//  swift-io
//
//  Worker with per-job watchdog for timeout enforcement.
//

import Synchronization

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

extension IO.Blocking.Lane.Abandoning {
    /// Worker that executes jobs with watchdog-based timeout.
    ///
    /// ## Design
    /// Each worker spawns a watchdog thread for each job. The watchdog:
    /// 1. Waits for the execution timeout duration
    /// 2. On timeout: CAS `.running → .timedOut`, resumes caller, and notifies
    ///    runtime to spawn replacement (since this worker is now abandoned)
    /// 3. On completion: Worker signals watchdog to exit early
    ///
    /// ## Abandon Semantics
    /// When a timeout occurs, the worker thread is "abandoned" - it remains
    /// blocked in the operation forever. The watchdog notifies the runtime
    /// to spawn a replacement worker immediately.
    ///
    /// ## CAS Discipline
    /// - Worker CAS `.pending → .running` on start
    /// - Worker CAS `.running → .completed` on completion
    /// - Watchdog CAS `.running → .timedOut` on timeout
    /// - Only one wins - single resume guaranteed
    struct Worker {
        let state: Runtime.State
        let executionTimeout: Duration
    }
}

// MARK: - Run Loop

extension IO.Blocking.Lane.Abandoning.Worker {
    /// Main worker loop.
    func run() {
        while true {
            state.mutex.lock()

            // Wait for job or shutdown
            while state.queue.isEmpty && !state.isShutdown {
                state.condition.wait(mutex: state.mutex)
            }

            // Exit on shutdown with empty queue
            if state.isShutdown && state.queue.isEmpty {
                state.mutex.unlock()
                state.workerDidFinish(abandoned: false)
                return
            }

            // Dequeue job
            guard !state.queue.isEmpty else {
                state.mutex.unlock()
                continue
            }
            let job = state.queue.removeFirst()
            state.mutex.unlock()

            // Try to start job
            guard job.tryStart() else {
                // Job was cancelled before we could start it
                continue
            }

            // Execute with watchdog
            let result = executeWithWatchdog(job)

            switch result {
            case .completed:
                state.mutex.lock()
                state.completedTotal &+= 1
                state.mutex.unlock()

            case .abandoned:
                // Worker is now abandoned - watchdog already notified runtime
                // This worker thread will never return from here in practice
                // (we only reach this if operation eventually completes after timeout)
                return

            case .cancelled:
                // Job was cancelled during execution - continue to next job
                continue
            }
        }
    }
}

// MARK: - Execution

extension IO.Blocking.Lane.Abandoning.Worker {
    /// Execute job with watchdog timeout.
    private func executeWithWatchdog(_ job: IO.Blocking.Lane.Abandoning.Job) -> Execution.Result {
        // Synchronization for watchdog
        let watchdogMutex = Kernel.Thread.Mutex()
        let watchdogCondition = Kernel.Thread.Condition()

        // Capture state for watchdog to notify on timeout
        let runtimeState = self.state

        // Spawn watchdog thread
        do {
            _ = try Kernel.Thread.spawn { [job, executionTimeout, watchdogMutex, watchdogCondition, runtimeState] in
                watchdogMutex.lock()

                // Wait for timeout or completion signal
                let signaled = watchdogCondition.wait(mutex: watchdogMutex, timeout: executionTimeout)

                watchdogMutex.unlock()

                if !signaled {
                    // Timeout occurred - try to mark job as timed out
                    if job.tryTimeout() {
                        // We won the race - notify runtime this worker is abandoned
                        // Runtime will spawn replacement
                        runtimeState.workerDidFinish(abandoned: true)
                    }
                    // If we lost the race, worker completed successfully
                }
            }
        } catch {
            // Watchdog spawn failed - execute without timeout protection
            // This is a degraded mode, but better than failing entirely
        }

        // Execute the operation - this may block indefinitely
        let resultPtr = job.operation()

        // Signal watchdog that we're done (may already have exited on timeout)
        watchdogMutex.lock()
        watchdogCondition.signal()
        watchdogMutex.unlock()

        // Try to complete - may fail if watchdog won the race
        if job.tryComplete(resultPtr) {
            return .completed
        }

        // Watchdog won or job was cancelled
        // Destroy the result since no one will consume it
        Kernel.Handoff.Box.destroy(resultPtr)

        let currentState = job.state.load(ordering: .acquiring)
        switch currentState {
        case .timedOut:
            // Watchdog already notified runtime, we're abandoned
            return .abandoned
        case .cancelled:
            return .cancelled
        default:
            return .abandoned
        }
    }
}
