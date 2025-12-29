//
//  IO.Blocking.Lane.Sharded.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 29/12/2025.
//

import Synchronization

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
        count: Int? = nil,
        make: @Sendable () -> IO.Blocking.Lane
    ) -> IO.Blocking.Lane {
        let laneCount = count ?? IO.Platform.processorCount
        precondition(laneCount > 0, "Lane count must be > 0")

        let lanes = (0..<laneCount).map { _ in make() }
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
            run: { (deadline: IO.Blocking.Deadline?, operation: @Sendable @escaping () -> UnsafeMutableRawPointer) async throws(IO.Blocking.Failure) -> UnsafeMutableRawPointer in
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
