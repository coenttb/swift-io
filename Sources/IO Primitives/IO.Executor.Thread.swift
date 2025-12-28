//
//  IO.Executor.Thread.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 28/12/2025.
//

extension IO.Executor {
    /// A serial executor backed by a single dedicated OS thread.
    ///
    /// Conforms to both `SerialExecutor` (for actor pinning via `unownedExecutor`)
    /// and `TaskExecutor` (for `Task(executorPreference:)`).
    ///
    /// ## Thread Safety
    /// This type is `@unchecked Sendable` because it provides internal synchronization.
    /// Jobs are enqueued under lock and executed serially on the dedicated thread.
    ///
    /// ## Lifecycle
    /// The executor thread starts immediately upon initialization and runs until
    /// `shutdown()` is called. After shutdown, no new jobs can be enqueued.
    public final class Thread: SerialExecutor, TaskExecutor, @unchecked Sendable {
        private let sync: Synchronization
        private var jobs: JobQueue
        private var isRunning: Bool = true
        private var threadHandle: IO.Thread.Handle?

        /// Creates a new executor thread.
        ///
        /// The thread starts immediately and begins waiting for jobs.
        public init() {
            self.sync = Synchronization()
            self.jobs = JobQueue()

            // Retain self until the OS thread takes ownership.
            // Uses RetainedPointer for safe Sendable crossing.
            // spawn(_:_:) accepts the value explicitly, avoiding closure capture issues.
            self.threadHandle = IO.Thread.spawn(IO.RetainedPointer(self)) { retained in
                let executor = retained.take()
                executor.runLoop()
            }
        }

        // MARK: - SerialExecutor

        /// Enqueue a job for execution on this executor.
        public func enqueue(_ job: UnownedJob) {
            sync.withLock {
                guard isRunning else { return }
                jobs.enqueue(job)
            }
            sync.signal()
        }

        /// Returns an unowned reference to this executor.
        ///
        /// Used by actors to specify their custom executor via `unownedExecutor`.
        public func asUnownedSerialExecutor() -> UnownedSerialExecutor {
            UnownedSerialExecutor(ordinary: self)
        }

        // MARK: - TaskExecutor

        /// Enqueue an executor job for execution.
        ///
        /// This enables `Task(executorPreference:)` to work with this executor.
        public func enqueue(_ job: consuming ExecutorJob) {
            enqueue(UnownedJob(job))
        }

        // MARK: - Run Loop

        private func runLoop() {
            while true {
                let job: UnownedJob? = sync.withLock {
                    while jobs.isEmpty && isRunning {
                        sync.wait()
                    }
                    guard isRunning || !jobs.isEmpty else { return nil }
                    return jobs.dequeue()
                }
                guard let job else { return }
                job.runSynchronously(on: asUnownedSerialExecutor())
            }
        }

        // MARK: - Shutdown

        /// Shutdown the executor thread.
        ///
        /// Signals the run loop to exit after processing any remaining jobs,
        /// then waits for the thread to complete.
        ///
        /// - Precondition: Must NOT be called from the executor thread itself.
        ///   Doing so would deadlock (joining a thread from itself).
        /// - Precondition: Must be called exactly once before the executor is deallocated.
        /// - Precondition: Must not be called before the thread has started.
        public func shutdown() {
            guard let handle = threadHandle else {
                preconditionFailure(
                    "IO.Executor.Thread.shutdown() called on already-shutdown or never-started executor"
                )
            }

            precondition(
                !handle.isCurrentThread,
                "Cannot shutdown executor from its own thread - would deadlock on join"
            )

            sync.withLock {
                isRunning = false
            }
            sync.broadcast()
            handle.join()
            threadHandle = nil
        }

        deinit {
            precondition(
                threadHandle == nil,
                "IO.Executor.Thread must be explicitly shut down before deallocation"
            )
        }
    }
}
