//
//  IO.Lane.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 07/01/2026.
//

public import IO_Blocking
public import IO_Blocking_Threads

extension IO {
    /// A lane for executing blocking I/O operations.
    ///
    /// ## Overview
    ///
    /// Lanes provide a uniform interface for running blocking syscalls without
    /// starving Swift's cooperative thread pool. Use lanes with `IO.run` and `IO.open`
    /// to execute blocking operations safely.
    ///
    /// ## Usage
    ///
    /// ```swift
    /// // Use the shared lane (default)
    /// let result = try await IO.run(on: .shared) {
    ///     blockingFileRead(path)
    /// }
    ///
    /// // Custom lane with specific configuration
    /// let lane = IO.Lane.threads(workers: 4)
    /// let data = try await IO.run(on: lane, deadline: .after(.seconds(5))) {
    ///     try socket.read()
    /// }
    /// ```
    ///
    /// ## Lane Types
    ///
    /// - `.shared`: Process-scoped default lane, lazily initialized
    /// - `.inline`: Executes on caller's context (testing only, NOT for actual blocking I/O)
    /// - `.threads(workers:)`: Dedicated thread pool with configurable worker count
    /// - `.sharded(count:make:)`: Multiple independent lanes for reduced contention
    ///
    /// ## Error Handling
    ///
    /// Lane operations throw `IO.Lane.Error` for infrastructure failures:
    /// - `.cancelled`: Task was cancelled before or during execution
    /// - `.timeout`: Deadline expired before the operation could be accepted
    /// - `.shutdown`: Lane is shutting down and rejecting new work
    /// - `.overloaded`: Lane capacity is exhausted (queue full or too many waiters)
    public struct Lane: Sendable {
        /// The underlying blocking lane.
        @usableFromInline
        internal let _backing: IO.Blocking.Lane

        /// Creates a lane from a backing implementation.
        @usableFromInline
        internal init(_ backing: IO.Blocking.Lane) {
            self._backing = backing
        }
    }
}

// MARK: - Error

extension IO.Lane {
    /// Infrastructure errors from lane operations.
    ///
    /// ## Design
    ///
    /// This error type owns all lane lifecycle and operational concerns in a flat enum.
    /// It consolidates what was previously split between `IO.Lifecycle.Error` and
    /// `IO.Blocking.Lane.Error` into a single domain-owned type.
    ///
    /// ## Error Categories
    ///
    /// - **Lifecycle**: `shutdown` - lane is no longer accepting work
    /// - **Cancellation**: `cancelled` - task was cancelled
    /// - **Timeout**: `timeout` - deadline expired before acceptance
    /// - **Capacity**: `overloaded` - lane resources exhausted
    ///
    /// ## Pattern Matching
    ///
    /// ```swift
    /// do {
    ///     let value = try await IO.run { compute() }
    /// } catch {
    ///     switch error {
    ///     case .cancelled: // handle cancellation
    ///     case .timeout: // handle timeout
    ///     case .shutdown: // handle shutdown
    ///     case .overloaded: // handle overload
    ///     }
    /// }
    /// ```
    public enum Error: Swift.Error, Sendable, Equatable {
        /// The operation was cancelled.
        ///
        /// Task cancellation was detected before or during lane acceptance.
        case cancelled

        /// The deadline expired before acceptance.
        ///
        /// The lane queue was too busy to accept the operation before the deadline.
        case timeout

        /// The lane is shutting down.
        ///
        /// New operations are rejected. In-flight operations may complete.
        case shutdown

        /// The lane is overloaded.
        ///
        /// Either the job queue is full or waiter capacity is exhausted.
        /// Callers may retry with exponential backoff.
        case overloaded
    }
}

// MARK: - Error Boundary Mapping

extension IO.Lane.Error {
    /// Creates a lane error from the internal lifecycle-wrapped error.
    ///
    /// This is the boundary translation point - performed exactly once when
    /// errors cross from the internal `IO.Blocking.Lane` to the public `IO.Lane` API.
    @usableFromInline
    internal init(from lifecycleError: IO.Lifecycle.Error<IO.Blocking.Lane.Error>) {
        switch lifecycleError {
        case .cancellation:
            self = .cancelled
        case .timeout:
            self = .timeout
        case .shutdownInProgress:
            self = .shutdown
        case .failure(let blockingError):
            switch blockingError {
            case .queueFull, .overloaded:
                self = .overloaded
            case .internalInvariantViolation:
                // Internal invariant violations indicate bugs, not operational failures.
                // In release, map to overloaded; in debug, this should have trapped earlier.
                self = .overloaded
            }
        }
    }
}

// MARK: - CustomStringConvertible

extension IO.Lane.Error: CustomStringConvertible {
    public var description: String {
        switch self {
        case .cancelled: "cancelled"
        case .timeout: "timeout"
        case .shutdown: "shutdown"
        case .overloaded: "overloaded"
        }
    }
}

// MARK: - Factory Methods

extension IO.Lane {
    /// The shared default lane for blocking I/O operations.
    ///
    /// This instance is lazily initialized and process-scoped:
    /// - Uses a thread pool with default options (processor count workers)
    /// - Does **not** require `shutdown()` (process-scoped)
    /// - Suitable for the common case where you need simple blocking I/O
    ///
    /// ## Usage
    ///
    /// ```swift
    /// // Direct use with IO.run
    /// let result = try await IO.run(on: .shared) { blockingOperation() }
    ///
    /// // As default parameter
    /// let pool = IO.Pool(capacity: 16, on: .shared) { ... }
    /// ```
    ///
    /// ## Lifecycle
    ///
    /// - **Process-scoped singleton**: Lives for the entire process lifetime
    /// - **No shutdown required**: Worker threads clean up on process exit
    /// - **Lazy start**: Worker threads spawn on first operation
    public static let shared = Self(IO.Blocking.Lane.shared)

    /// An inline lane that executes on the caller's context.
    ///
    /// ## Warning
    ///
    /// This lane is **NOT** suitable for actual blocking I/O operations.
    /// Blocking on this lane will block the cooperative thread pool.
    ///
    /// ## Use Cases
    ///
    /// - Unit testing with mock operations
    /// - Swift Embedded targets without pthread
    /// - Debugging orchestration logic
    ///
    /// ## Cancellation
    ///
    /// Respects cancellation before execution. Once started, the operation
    /// runs to completion.
    public static var inline: Self {
        Self(.inline)
    }

    /// Creates a lane backed by a dedicated thread pool.
    ///
    /// ## Parameters
    ///
    /// - `options`: Thread pool configuration (defaults to processor count workers)
    ///
    /// ## Usage
    ///
    /// ```swift
    /// let lane = IO.Lane.threads(.init(workers: 4))
    /// defer { Task { await lane.shutdown() } }
    ///
    /// let result = try await IO.run(on: lane) { blockingOperation() }
    /// ```
    ///
    /// ## Lifecycle
    ///
    /// Unlike `.shared`, custom lanes require explicit `shutdown()` when no longer needed.
    public static func threads(_ options: IO.Blocking.Threads.Options = .init()) -> Self {
        Self(.threads(options))
    }

    /// Creates a sharded lane that distributes work across multiple independent lanes.
    ///
    /// ## Design
    ///
    /// Sharding reduces lock contention by distributing work across multiple
    /// independent lanes. Each lane has its own queue and workers, eliminating
    /// cross-lane contention.
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
    /// let lane = IO.Lane.sharded(count: 4) {
    ///     .threads(.init(workers: 1))
    /// }
    /// defer { Task { await lane.shutdown() } }
    /// ```
    ///
    /// ## Parameters
    ///
    /// - `count`: Number of lanes (defaults to processor count)
    /// - `make`: Factory that creates each lane
    ///
    /// - Returns: A lane that distributes work across the shards via round-robin.
    public static func sharded(
        count: IO.Blocking.Lane.Count? = nil,
        make: @Sendable () -> Self
    ) -> Self {
        Self(.sharded(count: count) {
            make()._backing
        })
    }
}

// MARK: - Shutdown

extension IO.Lane {
    /// Shuts down the lane, rejecting new operations.
    ///
    /// In-flight operations may complete. After shutdown returns, all worker
    /// resources have been released.
    ///
    /// ## Note
    ///
    /// The `.shared` lane does not need shutdown - it's process-scoped.
    /// Only call shutdown on lanes you created with `.threads()` or `.sharded()`.
    public func shutdown() async {
        await _backing.shutdown()
    }
}

// MARK: - Capabilities

extension IO.Lane {
    /// The capabilities this lane provides.
    public var capabilities: IO.Blocking.Capabilities {
        _backing.capabilities
    }
}
