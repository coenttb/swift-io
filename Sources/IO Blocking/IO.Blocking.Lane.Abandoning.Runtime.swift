//
//  IO.Blocking.Lane.Abandoning.Runtime.swift
//  swift-io
//
//  Internal runtime managing workers and job dispatch.
//

import Synchronization

extension IO.Blocking.Lane.Abandoning {
    /// Internal runtime managing workers and job dispatch.
    final class Runtime: @unchecked Sendable {
        let options: Options
        let state: State

        init(options: Options) {
            self.options = options
            self.state = State(options: options)
        }
    }
}

// MARK: - Run

extension IO.Blocking.Lane.Abandoning.Runtime {
    func run(
        deadline: IO.Blocking.Deadline?,
        _ operation: @Sendable @escaping () -> UnsafeMutableRawPointer
    ) async throws(IO.Lifecycle.Error<IO.Blocking.Lane.Error>) -> UnsafeMutableRawPointer {
        // Check cancellation upfront
        if Task.isCancelled {
            throw .cancellation
        }

        // Ensure workers are started
        state.startIfNeeded()

        // Create job with atomic state
        let job = IO.Blocking.Lane.Abandoning.Job(operation: operation)

        // Shared reference for cancellation handler
        let jobHolder = Mutex<IO.Blocking.Lane.Abandoning.Job?>(job)

        // Use non-throwing continuation with Sendable result type
        let result: IO.Blocking.Lane.Abandoning.Job.Result = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<IO.Blocking.Lane.Abandoning.Job.Result, Never>) in
                // Store continuation in job
                job.setContinuation(continuation)

                // Check cancellation race
                // tryFail resumes continuation internally if CAS succeeds
                if Task.isCancelled {
                    _ = job.tryFail(.cancellation)
                    return
                }

                state.sync.lock()

                // Check shutdown
                if state.isShutdown {
                    state.sync.unlock()
                    _ = job.tryFail(.shutdownInProgress)
                    return
                }

                // Check if we have capacity
                if state.activeWorkerCount == 0 && state.spawnedWorkerCount >= Int(options.workers.max) {
                    state.sync.unlock()
                    _ = job.tryFail(.failure(.overloaded))
                    return
                }

                // Try to enqueue
                if state.queue.count >= options.queue.limit {
                    state.sync.unlock()
                    _ = job.tryFail(.failure(.queueFull))
                    return
                }

                state.queue.enqueue(job)
                state.sync.signal(condition: 0)
                state.sync.unlock()

                // Job enqueued - worker will complete it or watchdog will timeout
            }
        } onCancel: {
            // Try to cancel the job
            // tryCancel resumes continuation internally if CAS succeeds
            jobHolder.withLock { job in
                if let job = job {
                    _ = job.tryCancel()
                }
            }
        }

        // Unwrap at the boundary: convert Sendable boxed pointer back to raw
        switch result {
        case .success(let boxedPtr):
            return boxedPtr.raw  // Unwrap Sendable wrapper
        case .failure(let error):
            throw error
        }
    }
}

// MARK: - Shutdown

extension IO.Blocking.Lane.Abandoning.Runtime {
    func shutdown() async {
        state.sync.lock()
        state.isShutdown = true
        state.sync.broadcast(condition: 0)
        state.sync.unlock()

        // Wait for active workers to finish
        // Note: Abandoned workers are detached and won't be joined
        state.sync.lock()
        while state.activeWorkerCount > 0 {
            state.sync.wait(condition: 1)
        }
        state.sync.unlock()
    }
}

// MARK: - Metrics

extension IO.Blocking.Lane.Abandoning.Runtime {
    func metrics() -> IO.Blocking.Lane.Abandoning.Metrics {
        state.sync.lock()
        defer { state.sync.unlock() }
        return IO.Blocking.Lane.Abandoning.Metrics(
            workers: IO.Blocking.Lane.Abandoning.Metrics.Workers(
                abandoned: state.abandonedWorkerCount,
                active: state.activeWorkerCount,
                spawned: state.spawnedWorkerCount
            ),
            queue: IO.Blocking.Lane.Abandoning.Metrics.Queue(depth: state.queue.count),
            total: IO.Blocking.Lane.Abandoning.Metrics.Total(
                completed: state.completedTotal,
                abandoned: state.abandonedTotal
            )
        )
    }
}
