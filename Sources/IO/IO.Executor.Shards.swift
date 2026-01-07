//
//  IO.Executor.Shards.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 28/12/2025.
//

import Synchronization
import IO_Blocking

extension IO.Executor {
    /// A sharded collection of pools for reduced actor contention.
    ///
    /// ## Design
    ///
    /// Shards distributes work across multiple independent `Pool` instances.
    /// Each shard is a full Pool with its own:
    /// - Actor isolation (no cross-shard contention)
    /// - Handle registry
    /// - Waiter queues
    ///
    /// ## Routing
    ///
    /// Handles are assigned to shards at registration time via atomic round-robin.
    /// The shard index is stored in `IO.Handle.ID.shard`, enabling O(1) routing
    /// for all subsequent operations.
    ///
    /// ## Lane Factory Pattern
    ///
    /// The `laneFactory` closure creates a lane for each shard. This allows:
    /// - **Per-shard lanes**: Each shard gets its own lane (maximum isolation)
    /// - **Shared lane**: Factory returns the same lane (shared blocking pool)
    ///
    /// ## Usage
    ///
    /// ```swift
    /// // Per-shard lanes (maximum isolation)
    /// let shards = IO.Executor.Shards<FileHandle>(
    ///     count: 4,
    ///     laneFactory: { .threads() }
    /// )
    ///
    /// // Shared lane (reduced thread count)
    /// let sharedLane = IO.Blocking.Lane.threads()
    /// let shards = IO.Executor.Shards<FileHandle>(
    ///     count: 4,
    ///     laneFactory: { sharedLane }
    /// )
    /// ```
    ///
    /// `@unchecked Sendable` because:
    /// - `pools` is immutable after init
    /// - `counter` uses atomic operations for thread-safe increment
    internal final class Shards<Resource: ~Copyable & Sendable>: @unchecked Sendable {
        /// The underlying pools, one per shard.
        private let pools: [IO.Executor.Pool<Resource>]

        /// Atomic counter for round-robin shard selection.
        private let counter: Atomic<UInt64>

        /// Creates a sharded pool collection.
        ///
        /// - Parameters:
        ///   - count: Number of shards (must be > 0 and <= UInt16.max).
        ///   - laneFactory: Creates a lane for each shard. Called `count` times.
        ///   - policy: Backpressure policy for each shard (default: `.default`).
        internal init(
            count: Int,
            laneFactory: @Sendable () -> IO.Blocking.Lane,
            policy: IO.Backpressure.Policy = .default
        ) {
            precondition(count > 0 && count <= Int(UInt16.max), "Shard count must be 1...65535")
            self.pools = (0..<count).map { shardIndex in
                IO.Executor.Pool<Resource>(
                    lane: laneFactory(),
                    policy: policy,
                    shardIndex: UInt16(shardIndex)
                )
            }
            self.counter = Atomic(0)
        }

        /// Creates a sharded pool collection with explicit executors.
        ///
        /// - Parameters:
        ///   - count: Number of shards (must be > 0 and <= UInt16.max).
        ///   - laneFactory: Creates a lane for each shard.
        ///   - executorFactory: Creates an executor for each shard.
        ///   - policy: Backpressure policy for each shard.
        internal init(
            count: Int,
            laneFactory: @Sendable () -> IO.Blocking.Lane,
            executorFactory: @Sendable () -> Kernel.Thread.Executor,
            policy: IO.Backpressure.Policy = .default
        ) {
            precondition(count > 0 && count <= Int(UInt16.max), "Shard count must be 1...65535")
            self.pools = (0..<count).map { shardIndex in
                IO.Executor.Pool<Resource>(
                    lane: laneFactory(),
                    policy: policy,
                    executor: executorFactory(),
                    shardIndex: UInt16(shardIndex)
                )
            }
            self.counter = Atomic(0)
        }
    }
}

// MARK: - Properties

extension IO.Executor.Shards {
    /// The number of shards.
    internal var count: Int { pools.count }
}

// MARK: - Registration

extension IO.Executor.Shards {
    /// Register a resource and return its ID.
    ///
    /// Uses round-robin to select the shard. The shard index is stored
    /// in the returned ID for O(1) routing.
    ///
    /// - Parameter resource: The resource to register (ownership transferred).
    /// - Returns: A unique handle ID with embedded shard affinity.
    /// - Throws: `IO.Lifecycle.Error` if all shards are shut down.
    internal func register(
        _ resource: consuming Resource
    ) async throws(IO.Lifecycle.Error<IO.Handle.Error>) -> IO.Handle.ID {
        let index = counter.wrappingAdd(1, ordering: .relaxed).oldValue
        let shardIndex = Int(index % UInt64(pools.count))
        return try await pools[shardIndex].register(resource)
    }
}

// MARK: - Transaction API

extension IO.Executor.Shards {
    /// Execute a transaction with exclusive handle access.
    ///
    /// Routes to the correct shard via `id.shard`.
    ///
    /// - Parameters:
    ///   - id: The handle ID (must have been created by this Shards instance).
    ///   - body: The operation to execute with exclusive access.
    /// - Returns: The result of the body closure.
    /// - Throws: `IO.Lifecycle.Error` with transaction errors.
    internal func transaction<T: Sendable, E: Swift.Error & Sendable>(
        _ id: IO.Handle.ID,
        _ body: @Sendable @escaping (inout Resource) throws(E) -> T
    ) async throws(IO.Lifecycle.Error<IO.Executor.Transaction.Error<E>>) -> T {
        guard id.shard < pools.count else {
            throw .failure(.handle(.scopeMismatch))
        }
        return try await pools[Int(id.shard)].transaction(id, body)
    }

    /// Execute a closure with exclusive access to a handle.
    ///
    /// This is a convenience wrapper over `transaction(_:_:)`.
    internal func withHandle<T: Sendable, E: Swift.Error & Sendable>(
        _ id: IO.Handle.ID,
        _ body: @Sendable @escaping (inout Resource) throws(E) -> T
    ) async throws(IO.Lifecycle.Error<IO.Error<E>>) -> T {
        guard id.shard < pools.count else {
            throw .failure(.handle(.scopeMismatch))
        }
        return try await pools[Int(id.shard)].withHandle(id, body)
    }
}

// MARK: - Handle Validation

extension IO.Executor.Shards {
    /// Check if a handle ID refers to an open handle.
    ///
    /// - Parameter id: The handle ID to check.
    /// - Returns: `true` if the handle is logically open.
    internal func isOpen(_ id: IO.Handle.ID) async -> Bool {
        guard id.shard < pools.count else { return false }
        return await pools[Int(id.shard)].isOpen(id)
    }

    /// Check if a handle ID is currently valid.
    ///
    /// - Parameter id: The handle ID to check.
    /// - Returns: `true` if the handle exists and is not destroyed.
    internal func isValid(_ id: IO.Handle.ID) async -> Bool {
        guard id.shard < pools.count else { return false }
        return await pools[Int(id.shard)].isValid(id)
    }
}

// MARK: - Handle Destruction

extension IO.Executor.Shards {
    /// Mark a handle for destruction.
    ///
    /// - Parameter id: The handle ID.
    /// - Throws: `IO.Handle.Error` if the ID is invalid.
    internal func destroy(_ id: IO.Handle.ID) async throws(IO.Handle.Error) {
        guard id.shard < pools.count else {
            throw .scopeMismatch
        }
        try await pools[Int(id.shard)].destroy(id)
    }
}

// MARK: - Shutdown

extension IO.Executor.Shards {
    /// Shut down all shards.
    ///
    /// Shards are shut down concurrently for faster cleanup.
    internal func shutdown() async {
        await withTaskGroup(of: Void.self) { group in
            for pool in pools {
                group.addTask { await pool.shutdown() }
            }
        }
    }
}
