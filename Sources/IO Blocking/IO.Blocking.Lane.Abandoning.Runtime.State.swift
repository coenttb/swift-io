//
//  IO.Blocking.Lane.Abandoning.Runtime.State.swift
//  swift-io
//
//  Shared state for the abandoning runtime.
//

extension IO.Blocking.Lane.Abandoning.Runtime {
    final class State: @unchecked Sendable {
        /// Synchronization with 2 condition variables:
        /// - condition 0: work available (for worker threads)
        /// - condition 1: shutdown complete (for shutdown waiter)
        let sync = Kernel.Thread.Synchronization<2>()

        var queue = Kernel.Thread.Queue<IO.Blocking.Lane.Abandoning.Job>()
        var isShutdown = false
        var isStarted = false

        var activeWorkerCount: Int = 0
        var abandonedWorkerCount: Int = 0
        var spawnedWorkerCount: Int = 0

        var completedTotal: UInt64 = 0
        var abandonedTotal: UInt64 = 0

        let options: IO.Blocking.Lane.Abandoning.Options

        init(options: IO.Blocking.Lane.Abandoning.Options) {
            self.options = options
        }
    }
}

// MARK: - Worker Management

extension IO.Blocking.Lane.Abandoning.Runtime.State {
    func startIfNeeded() {
        sync.lock()
        defer { sync.unlock() }

        guard !isStarted else { return }
        isStarted = true

        // Spawn initial workers
        for _ in 0..<Int(options.workers.initial) {
            spawnWorker()
        }
    }

    func spawnWorker() {
        // Must be called with sync lock held
        spawnedWorkerCount += 1
        activeWorkerCount += 1

        let workerState = self
        let executionTimeout = options.execution.timeout

        // Spawn worker thread
        do {
            _ = try Kernel.Thread.spawn { [workerState, executionTimeout] in
                IO.Blocking.Lane.Abandoning.Worker(
                    state: workerState,
                    executionTimeout: executionTimeout
                ).run()
            }
        } catch {
            // Thread spawn failed - decrement counts
            spawnedWorkerCount -= 1
            activeWorkerCount -= 1
        }
    }

    func workerDidFinish(abandoned: Bool) {
        sync.lock()
        activeWorkerCount -= 1

        if abandoned {
            abandonedWorkerCount += 1
            abandonedTotal &+= 1

            // Try to spawn replacement if under limit
            if spawnedWorkerCount < Int(options.workers.max) && !isShutdown {
                spawnWorker()
            }
        }

        // Signal shutdown waiter (condition 1) if no more active workers
        if activeWorkerCount == 0 {
            sync.signal(condition: 1)
        }
        sync.unlock()
    }
}
