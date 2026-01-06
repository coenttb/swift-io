//
//  IO.Blocking.Lane.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 24/12/2025.
//

// NOTE: Lane is an execution backend abstraction.
// Do not assume Threads is the only implementation.
// Future: may be backed by platform executors (swift-platform-executors).

import Synchronization

extension IO.Blocking {
    /// Protocol witness struct for blocking I/O lanes.
    ///
    /// ## Design
    /// Lanes provide a uniform interface for running blocking syscalls without
    /// starving Swift's cooperative thread pool. This is a protocol witness struct
    /// (not a protocol) to avoid existential types for Swift Embedded compatibility.
    ///
    /// ## Error Handling Design
    /// - Lane throws `Failure` for infrastructure failures (shutdown, timeout, etc.)
    /// - Operation errors flow through `Result<T, E>` - never thrown
    /// - This enables typed error propagation without existentials
    ///
    /// ## Cancellation Contract
    /// - **Before acceptance**: If task is cancelled before the lane accepts the job,
    ///   `run()` throws `.cancellationRequested` immediately without enqueuing.
    /// - **After acceptance**: If `guaranteesRunOnceEnqueued` is true, the job runs
    ///   to completion. The caller may observe `.cancellationRequested` upon return,
    ///   but the operation's side effects occur.
    ///
    /// ## Cancellation Law
    /// Once a lane accepts an operation, it will execute exactly once.
    /// Cancellation may prevent waiting, but never execution.
    /// Cancellation may cause the caller to stop waiting and not observe the result,
    /// but the lane will still drain and destroy the completion.
    ///
    /// ## Deadline Contract
    /// - Deadlines bound acceptance time (waiting to enqueue), not execution time.
    /// - Lanes are not required to interrupt syscalls once executing.
    /// - If deadline expires before acceptance, throw `.deadlineExceeded`.
    public struct Lane: Sendable {
        /// The capabilities this lane provides.
        public let capabilities: Capabilities

        /// The run implementation.
        /// - Operation closure returns boxed value (never throws)
        /// - Lane throws IO.Lifecycle.Error for lifecycle/infrastructure failures
        package let _run:
            @Sendable @concurrent (
                Deadline?,
                @Sendable @escaping () -> UnsafeMutableRawPointer  // Returns boxed value
            ) async throws(IO.Lifecycle.Error<IO.Blocking.Lane.Error>) -> UnsafeMutableRawPointer

        private let _shutdown: @Sendable @concurrent () async -> Void

        public init(
            capabilities: Capabilities,
            run:
                @escaping @Sendable @concurrent (
                    Deadline?,
                    @Sendable @escaping () -> UnsafeMutableRawPointer
                ) async throws(IO.Lifecycle.Error<IO.Blocking.Lane.Error>) -> UnsafeMutableRawPointer,
            shutdown: @escaping @Sendable @concurrent () async -> Void
        ) {
            self.capabilities = capabilities
            self._run = run
            self._shutdown = shutdown
        }
    }
}

// MARK: - Core Primitive (Result-returning)

extension IO.Blocking.Lane {
    /// Execute a Result-returning operation.
    ///
    /// This is the core primitive. The operation produces a `Result<T, E>` directly,
    /// preserving the typed error without any casting or existentials.
    ///
    /// Internal to force callers through the typed-throws `run` wrapper.
    /// Lane throws `IO.Lifecycle.Error<IO.Blocking.Lane.Error>` for lifecycle/infrastructure failures.
    @concurrent
    internal func run<T: Sendable, E: Swift.Error & Sendable>(
        deadline: IO.Blocking.Deadline?,
        _ operation: @Sendable @escaping () -> Result<T, E>
    ) async throws(IO.Lifecycle.Error<IO.Blocking.Lane.Error>) -> Result<T, E> {
        let ptr = try await _run(deadline) {
            let result = operation()
            return Kernel.Handoff.Box.make(result)
        }
        return Kernel.Handoff.Box.take(ptr)
    }
}

// MARK: - Convenience (Typed-Throws)

extension IO.Blocking.Lane {
    /// Execute a typed-throwing operation, returning Result.
    ///
    /// This convenience wrapper converts `throws(E) -> T` to `() -> Result<T, E>`.
    ///
    /// ## Quarantined Cast (Swift Embedded Safe)
    /// Swift currently infers `error` as `any Error` even when `operation` throws(E).
    /// We use a single, localized `as?` cast to recover E without introducing
    /// existentials into storage or API boundaries. This is the ONLY cast in the
    /// module and is acceptable for Embedded compatibility.
    @concurrent
    public func run<T: Sendable, E: Swift.Error & Sendable>(
        deadline: IO.Blocking.Deadline?,
        _ operation: @Sendable @escaping () throws(E) -> T
    ) async throws(IO.Lifecycle.Error<IO.Blocking.Lane.Error>) -> Result<T, E> {
        try await run(deadline: deadline) {
            do {
                return .success(try operation())
            } catch {
                // Quarantined cast to recover E from `any Error`.
                // This is the only cast in the module - do not add others.
                guard let e = error as? E else {
                    // Unreachable if typed-throws is respected by the compiler.
                    // Trap to surface invariant violations during development.
                    fatalError(
                        "Lane.run: typed-throws invariant violated. Expected \(E.self), got \(type(of: error))"
                    )
                }
                return .failure(e)
            }
        }
    }
}

// MARK: - Convenience (Non-throwing)

extension IO.Blocking.Lane {
    /// Execute a non-throwing operation, returning value directly.
    @concurrent
    public func run<T: Sendable>(
        deadline: IO.Blocking.Deadline?,
        _ operation: @Sendable @escaping () -> T
    ) async throws(IO.Lifecycle.Error<IO.Blocking.Lane.Error>) -> T {
        let ptr = try await _run(deadline) {
            let result = operation()
            return Kernel.Handoff.Box.makeValue(result)
        }
        return Kernel.Handoff.Box.takeValue(ptr)
    }
}

// MARK: - Shutdown

extension IO.Blocking.Lane {
    @concurrent
    public func shutdown() async {
        await _shutdown()
    }
}

extension IO.Blocking.Lane {
    /// An inline lane that executes on the caller's context.
    ///
    /// ## Warning
    /// This lane is NOT suitable for actual blocking I/O operations.
    /// Blocking on this lane will block the cooperative thread pool.
    ///
    /// ## Use Cases
    /// - Unit testing with mock operations
    /// - Swift Embedded targets without pthread
    /// - Debugging orchestration logic
    ///
    /// ## Capabilities
    /// - `executesOnDedicatedThreads`: false
    /// - `guaranteesRunOnceEnqueued`: true (immediate execution)
    ///
    /// ## Deadline Behavior
    /// Deadlines are checked once before execution. No queue exists,
    /// so there is no "acceptance wait" that could exceed a deadline.
    ///
    /// ## Cancellation
    /// Respects cancellation before execution. Once started,
    /// the operation runs to completion (same invariant as Threads lane).
    public static var inline: Self {
        Self(
            capabilities: IO.Blocking.Capabilities(
                executesOnDedicatedThreads: false,
                guaranteesRunOnceEnqueued: true
            ),
            run: {
                (
                    deadline: IO.Blocking.Deadline?,
                    operation: @Sendable @escaping () -> UnsafeMutableRawPointer
                ) async throws(IO.Lifecycle.Error<IO.Blocking.Lane.Error>) -> UnsafeMutableRawPointer in
                // Check cancellation before execution
                if Task.isCancelled {
                    throw .cancellation
                }
                // Check deadline (one-time check, no queue)
                if let deadline, deadline.hasExpired {
                    throw .timeout
                }
                // Execute immediately on caller's context
                return operation()
            },
            shutdown: {}
        )
    }
}

extension IO.Blocking.Lane {
    /// Creates a sharded lane that distributes work across multiple independent lanes.
    ///
    /// ## Design
    ///
    /// Sharding reduces lock contention by distributing work across multiple
    /// independent lanes. Each lane has its own queue and workers, eliminating
    /// cross-lane contention.
    ///
    /// ## Routing
    ///
    /// Work is assigned to lanes via atomic round-robin. This provides:
    /// - Even distribution across lanes
    /// - No routing state to maintain per-caller
    /// - O(1) lane selection
    ///
    /// ## Performance
    ///
    /// Under high contention, sharding reduces lock contention linearly with
    /// shard count. For N shards, each queue sees ~1/N of the traffic.
    ///
    /// ## Usage
    ///
    /// ```swift
    /// // 4 independent lanes, each with 1 worker (4 threads, 4 queues)
    /// let lane = IO.Blocking.Lane.sharded(count: 4) {
    ///     .threads(.init(workers: 1))
    /// }
    ///
    /// // Use like any other lane
    /// let result: Result<Data, MyError> = try await lane.run(deadline: .none) {
    ///     try readFile(path)
    /// }
    ///
    /// await lane.shutdown()
    /// ```
    ///
    /// ## Comparison
    ///
    /// | Configuration | Queues | Contention |
    /// |--------------|--------|------------|
    /// | `.threads(.init(workers: 4))` | 1 | High |
    /// | `.sharded(count: 4) { .threads(.init(workers: 1)) }` | 4 | Low |
    ///
    /// - Parameters:
    ///   - count: Number of lanes (default: processor count).
    ///   - make: Factory that creates each lane. Called `count` times.
    /// - Returns: A lane that distributes work across the shards.
    public static func sharded(
        count: IO.Blocking.Lane.Count? = nil,
        make: @Sendable () -> IO.Blocking.Lane
    ) -> IO.Blocking.Lane {
        let laneCount = count ?? IO.Blocking.Lane.Count(Kernel.System.processorCount)
        precondition(Int(laneCount) > 0, "Lane count must be > 0")

        let lanes = (0..<Int(laneCount)).map { _ in make() }
        let counter = Atomic<UInt64>(0)

        // Compute intersection of capabilities
        let capabilities: IO.Blocking.Capabilities = {
            guard let first = lanes.first else {
                return IO.Blocking.Capabilities(
                    executesOnDedicatedThreads: false,
                    guaranteesRunOnceEnqueued: false
                )
            }
            var caps = first.capabilities
            for lane in lanes.dropFirst() {
                caps = IO.Blocking.Capabilities(
                    executesOnDedicatedThreads: caps.executesOnDedicatedThreads && lane.capabilities.executesOnDedicatedThreads,
                    guaranteesRunOnceEnqueued: caps.guaranteesRunOnceEnqueued && lane.capabilities.guaranteesRunOnceEnqueued
                )
            }
            return caps
        }()

        return IO.Blocking.Lane(
            capabilities: capabilities,
            run: { (deadline: IO.Blocking.Deadline?, operation: @Sendable @escaping () -> UnsafeMutableRawPointer) async throws(IO.Lifecycle.Error<IO.Blocking.Lane.Error>) -> UnsafeMutableRawPointer in
                let index = counter.wrappingAdd(1, ordering: .relaxed).oldValue
                let lane = lanes[Int(index % UInt64(lanes.count))]
                return try await lane._run(deadline, operation)
            },
            shutdown: {
                await withTaskGroup(of: Void.self) { group in
                    for lane in lanes {
                        group.addTask { await lane.shutdown() }
                    }
                }
            }
        )
    }
}
