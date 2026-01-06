//
//  IO.Blocking.Lane.Abandoning.Runtime.State.swift
//  swift-io
//
//  Shared state for the abandoning runtime.
//

extension IO.Blocking.Lane.Abandoning.Runtime {
    final class State: @unchecked Sendable {
        let mutex = Kernel.Thread.Mutex()
        let condition = Kernel.Thread.Condition()
        let shutdownCondition = Kernel.Thread.Condition()

        var queue: [IO.Blocking.Lane.Abandoning.Job] = []
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
        mutex.lock()
        defer { mutex.unlock() }

        guard !isStarted else { return }
        isStarted = true

        // Spawn initial workers
        for _ in 0..<Int(options.workers.initial) {
            spawnWorker()
        }
    }

    func spawnWorker() {
        // Must be called with mutex held
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
        mutex.lock()
        activeWorkerCount -= 1

        if abandoned {
            abandonedWorkerCount += 1
            abandonedTotal &+= 1

            // Try to spawn replacement if under limit
            if spawnedWorkerCount < Int(options.workers.max) && !isShutdown {
                spawnWorker()
            }
        }

        // Signal shutdown waiter if no more active workers
        if activeWorkerCount == 0 {
            shutdownCondition.signal()
        }
        mutex.unlock()
    }
}
