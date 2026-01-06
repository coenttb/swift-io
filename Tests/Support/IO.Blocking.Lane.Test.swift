//
//  IO.Blocking.Lane.Test.swift
//  swift-io
//
//  Fault-tolerant test lane that can abandon hung operations.
//

public import IO_Blocking_Threads
internal import Kernel
import Synchronization

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

extension IO.Blocking.Lane {
    /// A fault-tolerant lane for testing that can abandon hung operations.
    ///
    /// ## Purpose
    /// Prevents a single hung synchronous operation from wedging the entire test suite.
    /// When an operation exceeds its timeout, the caller resumes with an error while
    /// the operation continues on an abandoned thread.
    ///
    /// ## Semantics: Abandon, Not Cancel
    /// - Timeout resumes the caller but does NOT cancel the operation
    /// - The abandoned operation may continue running on a detached thread
    /// - Side effects can outlive the test
    /// - Only suitable for tests with "pure-ish" or idempotent operations
    ///
    /// ## Usage
    /// ```swift
    /// let test = IO.Blocking.Lane.test(.init(executionTimeout: .seconds(5)))
    ///
    /// let result = try await test.lane.run(deadline: nil) {
    ///     // This operation will be abandoned if it takes > 5 seconds
    ///     someBlockingOperation()
    /// }
    ///
    /// // Check metrics
    /// let metrics = test.metrics()
    /// print("Abandoned: \(metrics.abandonedWorkers)")
    ///
    /// await test.lane.shutdown()
    /// ```
    public struct Test: Sendable {
        /// The underlying lane.
        public let lane: IO.Blocking.Lane

        /// The runtime (internal, for metrics access).
        private let runtime: Runtime

        /// Creates a test lane with the given options.
        internal init(options: Options) {
            let runtime = Runtime(options: options)
            self.runtime = runtime
            self.lane = IO.Blocking.Lane(
                capabilities: IO.Blocking.Capabilities(
                    executesOnDedicatedThreads: true,
                    executionSemantics: .abandonOnExecutionTimeout
                ),
                run: { (deadline, operation) async throws(IO.Lifecycle.Error<IO.Blocking.Lane.Error>) in
                    try await runtime.run(deadline: deadline, operation)
                },
                shutdown: {
                    await runtime.shutdown()
                }
            )
        }

        /// Returns current metrics snapshot.
        public func metrics() -> Metrics {
            runtime.metrics()
        }
    }
}

// MARK: - Factory

extension IO.Blocking.Lane {
    /// Creates a fault-tolerant test lane.
    ///
    /// Use this lane in test scenarios where operations may hang indefinitely.
    /// The lane will abandon hung operations after the configured timeout.
    ///
    /// - Parameter options: Configuration options.
    /// - Returns: A test wrapper containing the lane and metrics access.
    public static func test(_ options: Test.Options = .init()) -> Test {
        Test(options: options)
    }
}

// MARK: - Metrics

extension IO.Blocking.Lane.Test {
    /// Metrics snapshot for the test lane.
    public struct Metrics: Sendable {
        /// Number of workers that have been abandoned due to timeout.
        public var abandonedWorkers: Int

        /// Number of currently active workers (not abandoned).
        public var activeWorkers: Int

        /// Total number of workers spawned since creation.
        public var spawnedWorkers: Int

        /// Current queue depth.
        public var queueDepth: Int

        /// Total operations completed successfully.
        public var completedTotal: UInt64

        /// Total operations abandoned due to timeout.
        public var abandonedTotal: UInt64
    }
}

// MARK: - Runtime

extension IO.Blocking.Lane.Test {
    /// Internal runtime managing workers and job dispatch.
    final class Runtime: @unchecked Sendable {
        let options: Options
        let state: State

        init(options: Options) {
            self.options = options
            self.state = State(options: options)
        }

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
            let job = Job(operation: operation)

            // Shared reference for cancellation handler
            let jobHolder = Mutex<Job?>(job)

            // Use non-throwing continuation with Sendable result type
            let result: Job.Result = await withTaskCancellationHandler {
                await withCheckedContinuation { (continuation: CheckedContinuation<Job.Result, Never>) in
                    // Store continuation in job
                    job.setContinuation(continuation)

                    // Check cancellation race
                    // tryFail resumes continuation internally if CAS succeeds
                    if Task.isCancelled {
                        _ = job.tryFail(.cancellation)
                        return
                    }

                    state.mutex.lock()

                    // Check shutdown
                    if state.isShutdown {
                        state.mutex.unlock()
                        _ = job.tryFail(.shutdownInProgress)
                        return
                    }

                    // Check if we have capacity
                    if state.activeWorkerCount == 0 && state.spawnedWorkerCount >= Int(options.maxWorkers) {
                        state.mutex.unlock()
                        _ = job.tryFail(.failure(.overloaded))
                        return
                    }

                    // Try to enqueue
                    if state.queue.count >= options.queueLimit {
                        state.mutex.unlock()
                        _ = job.tryFail(.failure(.queueFull))
                        return
                    }

                    state.queue.append(job)
                    state.condition.signal()
                    state.mutex.unlock()

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

        func shutdown() async {
            state.mutex.lock()
            state.isShutdown = true
            state.condition.broadcast()
            state.mutex.unlock()

            // Wait for active workers to finish
            // Note: Abandoned workers are detached and won't be joined
            state.mutex.lock()
            while state.activeWorkerCount > 0 {
                state.shutdownCondition.wait(mutex: state.mutex)
            }
            state.mutex.unlock()
        }

        func metrics() -> Metrics {
            state.mutex.lock()
            defer { state.mutex.unlock() }
            return Metrics(
                abandonedWorkers: state.abandonedWorkerCount,
                activeWorkers: state.activeWorkerCount,
                spawnedWorkers: state.spawnedWorkerCount,
                queueDepth: state.queue.count,
                completedTotal: state.completedTotal,
                abandonedTotal: state.abandonedTotal
            )
        }
    }
}

// MARK: - State

extension IO.Blocking.Lane.Test.Runtime {
    final class State: @unchecked Sendable {
        let mutex = Kernel.Thread.Mutex()
        let condition = Kernel.Thread.Condition()
        let shutdownCondition = Kernel.Thread.Condition()

        var queue: [IO.Blocking.Lane.Test.Job] = []
        var isShutdown = false
        var isStarted = false

        var activeWorkerCount: Int = 0
        var abandonedWorkerCount: Int = 0
        var spawnedWorkerCount: Int = 0

        var completedTotal: UInt64 = 0
        var abandonedTotal: UInt64 = 0

        let options: IO.Blocking.Lane.Test.Options

        init(options: IO.Blocking.Lane.Test.Options) {
            self.options = options
        }

        func startIfNeeded() {
            mutex.lock()
            defer { mutex.unlock() }

            guard !isStarted else { return }
            isStarted = true

            // Spawn initial workers
            for _ in 0..<Int(options.workers) {
                spawnWorker()
            }
        }

        func spawnWorker() {
            // Must be called with mutex held
            spawnedWorkerCount += 1
            activeWorkerCount += 1

            let workerState = self
            let executionTimeout = options.executionTimeout

            // Spawn worker thread
            do {
                _ = try Kernel.Thread.spawn { [workerState, executionTimeout] in
                    IO.Blocking.Lane.Test.Worker(
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
                if spawnedWorkerCount < Int(options.maxWorkers) && !isShutdown {
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
}

// MARK: - Job

extension IO.Blocking.Lane.Test {
    /// A job with atomic state for single-resume guarantee.
    final class Job: @unchecked Sendable {
        /// Sendable success type for crossing concurrency boundaries.
        ///
        /// `UnsafeMutableRawPointer` is not Sendable. This wrapper concentrates
        /// the `@unchecked Sendable` at the handoff boundary.
        typealias Success = Kernel.Handoff.Box.Pointer

        /// Sendable result type for continuation resume.
        typealias Result = Swift.Result<Success, IO.Lifecycle.Error<IO.Blocking.Lane.Error>>

        /// Atomic state for CAS discipline.
        enum State: UInt8, AtomicRepresentable {
            case pending = 0
            case running = 1
            case completed = 2
            case timedOut = 3
            case cancelled = 4
            case failed = 5
        }

        let operation: @Sendable () -> UnsafeMutableRawPointer
        let state: Atomic<State>
        private var continuation: CheckedContinuation<Result, Never>?
        private let lock = Kernel.Thread.Mutex()

        init(operation: @Sendable @escaping () -> UnsafeMutableRawPointer) {
            self.operation = operation
            self.state = Atomic(.pending)
        }

        func setContinuation(_ cont: CheckedContinuation<Result, Never>) {
            lock.lock()
            self.continuation = cont
            lock.unlock()
        }

        /// Attempt to start running. Returns true if successful.
        func tryStart() -> Bool {
            let (exchanged, _) = state.compareExchange(
                expected: .pending,
                desired: .running,
                ordering: .acquiringAndReleasing
            )
            return exchanged
        }

        /// Attempt to complete successfully. Returns true if successful.
        ///
        /// Wraps the raw pointer in a Sendable container before resuming.
        func tryComplete(_ rawResult: UnsafeMutableRawPointer) -> Bool {
            let (exchanged, _) = state.compareExchange(
                expected: .running,
                desired: .completed,
                ordering: .acquiringAndReleasing
            )
            if exchanged {
                // Wrap at boundary: convert raw pointer to Sendable wrapper
                let boxedPtr = Success(rawResult)
                lock.lock()
                let cont = continuation
                continuation = nil
                lock.unlock()
                cont?.resume(returning: .success(boxedPtr))
            }
            return exchanged
        }

        /// Attempt to mark as timed out. Returns true if successful.
        func tryTimeout() -> Bool {
            let (exchanged, _) = state.compareExchange(
                expected: .running,
                desired: .timedOut,
                ordering: .acquiringAndReleasing
            )
            if exchanged {
                lock.lock()
                let cont = continuation
                continuation = nil
                lock.unlock()
                cont?.resume(returning: .failure(.timeout))
            }
            return exchanged
        }

        /// Attempt to cancel. Returns true if successful.
        func tryCancel() -> Bool {
            // Can cancel from pending or running
            var (exchanged, original) = state.compareExchange(
                expected: .pending,
                desired: .cancelled,
                ordering: .acquiringAndReleasing
            )
            if !exchanged && original == .running {
                (exchanged, _) = state.compareExchange(
                    expected: .running,
                    desired: .cancelled,
                    ordering: .acquiringAndReleasing
                )
            }
            if exchanged {
                lock.lock()
                let cont = continuation
                continuation = nil
                lock.unlock()
                cont?.resume(returning: .failure(.cancellation))
            }
            return exchanged
        }

        /// Attempt to fail with error. Returns true if successful.
        func tryFail(_ error: IO.Lifecycle.Error<IO.Blocking.Lane.Error>) -> Bool {
            // Can fail from pending only
            let (exchanged, _) = state.compareExchange(
                expected: .pending,
                desired: .failed,
                ordering: .acquiringAndReleasing
            )
            if exchanged {
                lock.lock()
                let cont = continuation
                continuation = nil
                lock.unlock()
                cont?.resume(returning: .failure(error))
            }
            return exchanged
        }
    }
}
