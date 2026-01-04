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
    /// ## Lifecycle Requirements
    ///
    /// **IMPORTANT**: This type has strict lifecycle requirements:
    ///
    /// 1. **Must call `shutdown()` before deallocation**: The executor owns an OS thread
    ///    that must be explicitly joined. Failing to call `shutdown()` before the executor
    ///    is deallocated will trap with a diagnostic message.
    ///
    /// 2. **Cannot shutdown from executor's own thread**: Calling `shutdown()` from a job
    ///    running on the executor would deadlock (joining a thread from itself). This is
    ///    detected and traps with a diagnostic message.
    ///
    /// 3. **Shutdown is idempotent-ish**: Calling `shutdown()` on an already-shutdown
    ///    executor traps. Call exactly once.
    ///
    /// ## Example Usage
    /// ```swift
    /// let executor = IO.Executor.Thread()
    /// defer { executor.shutdown() }
    ///
    /// // Pin an actor to this executor
    /// actor MyActor {
    ///     nonisolated var unownedExecutor: UnownedSerialExecutor {
    ///         executor.asUnownedSerialExecutor()
    ///     }
    /// }
    /// ```
    ///
    /// ## Why These Traps Exist
    /// These preconditions exist because silent failure would be worse:
    /// - Leaking an OS thread is a resource leak that compounds over time
    /// - Joining from self is undefined behavior on some platforms
    /// - Double-shutdown indicates a logic error in the caller
    ///
    /// If you need a more forgiving API, consider wrapping this in a helper that
    /// tracks shutdown state and handles edge cases for your use case.
    public final class Thread: SerialExecutor, TaskExecutor, @unchecked Sendable {
        private let sync: Synchronization
        private var jobs: Job.Queue
        private var isRunning: Bool = true
        private var threadHandle: IO.Thread.Handle?

        /// Creates a new executor thread.
        ///
        /// The thread starts immediately and begins waiting for jobs.
        public init() {
            self.sync = Synchronization()
            self.jobs = Job.Queue()

            // Retain self until the OS thread takes ownership.
            // Uses IO.Pointer.Retained for safe Sendable crossing.
            // trap(_:_:) accepts the value explicitly, avoiding closure capture issues.
            //
            // Thread creation failure here is catastrophic - the executor cannot function
            // without its thread. We use IO.Thread.trap because:
            // 1. Most callers cannot recover from thread exhaustion
            // 2. Making init() throwing would cascade through the entire API
            // 3. Thread creation failure typically indicates system-wide resource exhaustion
            self.threadHandle = IO.Thread.trap(IO.Pointer.Retained(self)) { retained in
                let executor = retained.take()
                executor.runLoop()
            }
        }

        deinit {
            precondition(
                threadHandle == nil,
                "IO.Executor.Thread must be explicitly shut down before deallocation"
            )
        }
    }
}

// MARK: - SerialExecutor

extension IO.Executor.Thread {
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
}

// MARK: - TaskExecutor

extension IO.Executor.Thread {
    /// Enqueue an executor job for execution.
    ///
    /// This enables `Task(executorPreference:)` to work with this executor.
    public func enqueue(_ job: consuming ExecutorJob) {
        enqueue(UnownedJob(job))
    }
}

// MARK: - Run Loop

extension IO.Executor.Thread {
    fileprivate func runLoop() {
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
}

// MARK: - Shutdown

extension IO.Executor.Thread {
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
        // Take ownership of the handle from storage.
        // Using explicit _take pattern for ~Copyable Optional.
        guard let handle = threadHandle._take() else {
            preconditionFailure(
                "IO.Executor.Thread.shutdown() called on already-shutdown or never-started executor"
            )
        }

        precondition(
            !handle.isCurrent,
            "Cannot shutdown executor from its own thread - would deadlock on join"
        )

        sync.withLock {
            isRunning = false
        }
        sync.broadcast()
        handle.join()
    }
}
