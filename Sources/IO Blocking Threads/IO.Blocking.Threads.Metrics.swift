//
//  IO.Blocking.Threads.Metrics.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 06/01/2026.
//

import Synchronization

extension IO.Blocking.Threads {
    /// Lock-free atomic counters for metrics tracking.
    ///
    /// ## Design
    /// All counters use relaxed atomic ordering because:
    /// - Writes are independent of each other (monotonic increments)
    /// - Reads are for telemetry (eventual consistency is acceptable)
    /// - No synchronization-with relationships are required
    ///
    /// ## Cache Locality
    /// Counters are grouped in a single struct to maximize cache locality.
    /// All counter updates happen on hot paths, so keeping them on the same
    /// cache line reduces memory traffic.
    ///
    /// ## Thread Safety
    /// Safe for concurrent access from multiple workers and the metrics reader.
    final class Counters: Sendable {
        private let _enqueued = Atomic<UInt64>(0)
        private let _started = Atomic<UInt64>(0)
        private let _completed = Atomic<UInt64>(0)
        private let _acceptancePromoted = Atomic<UInt64>(0)
        private let _acceptanceTimeout = Atomic<UInt64>(0)
        private let _failFast = Atomic<UInt64>(0)
        private let _overloaded = Atomic<UInt64>(0)
        private let _cancelled = Atomic<UInt64>(0)

        init() {}

        // MARK: - Increment Operations (Lock-Free)

        @inline(__always)
        func incrementEnqueued() {
            _ = _enqueued.wrappingAdd(1, ordering: .relaxed)
        }

        @inline(__always)
        func incrementStarted() {
            _ = _started.wrappingAdd(1, ordering: .relaxed)
        }

        @inline(__always)
        func incrementCompleted() {
            _ = _completed.wrappingAdd(1, ordering: .relaxed)
        }

        /// Batch increment for started counter.
        @inline(__always)
        func add(started count: Int) {
            _ = _started.wrappingAdd(UInt64(truncatingIfNeeded: count), ordering: .relaxed)
        }

        /// Batch increment for completed counter.
        @inline(__always)
        func add(completed count: Int) {
            _ = _completed.wrappingAdd(UInt64(truncatingIfNeeded: count), ordering: .relaxed)
        }

        @inline(__always)
        func incrementAcceptancePromoted() {
            _ = _acceptancePromoted.wrappingAdd(1, ordering: .relaxed)
        }

        @inline(__always)
        func incrementAcceptanceTimeout() {
            _ = _acceptanceTimeout.wrappingAdd(1, ordering: .relaxed)
        }

        @inline(__always)
        func incrementFailFast() {
            _ = _failFast.wrappingAdd(1, ordering: .relaxed)
        }

        @inline(__always)
        func incrementOverloaded() {
            _ = _overloaded.wrappingAdd(1, ordering: .relaxed)
        }

        @inline(__always)
        func incrementCancelled() {
            _ = _cancelled.wrappingAdd(1, ordering: .relaxed)
        }

        // MARK: - Read Operations (Lock-Free)

        var enqueued: UInt64 { _enqueued.load(ordering: .relaxed) }
        var started: UInt64 { _started.load(ordering: .relaxed) }
        var completed: UInt64 { _completed.load(ordering: .relaxed) }
        var acceptancePromoted: UInt64 { _acceptancePromoted.load(ordering: .relaxed) }
        var acceptanceTimeout: UInt64 { _acceptanceTimeout.load(ordering: .relaxed) }
        var failFast: UInt64 { _failFast.load(ordering: .relaxed) }
        var overloaded: UInt64 { _overloaded.load(ordering: .relaxed) }
        var cancelled: UInt64 { _cancelled.load(ordering: .relaxed) }
    }
}

extension IO.Blocking.Threads {
    /// Latency aggregate (no percentiles in v1).
    ///
    /// ## Design
    /// Simple aggregates that can be computed in O(1) under lock:
    /// - count: Number of samples
    /// - sumNs: Sum of all durations in nanoseconds
    /// - minNs: Minimum duration observed
    /// - maxNs: Maximum duration observed
    ///
    /// ## Computing Averages
    /// Average = sumNs / count (caller computes).
    ///
    /// ## Future
    /// P50/P99 require histogram support (HDR or t-digest) - deferred to v2.
    public struct Aggregate: Sendable, Equatable {
        public let count: UInt64
        public let sumNs: UInt64
        public let minNs: UInt64
        public let maxNs: UInt64

        public init(count: UInt64, sumNs: UInt64, minNs: UInt64, maxNs: UInt64) {
            self.count = count
            self.sumNs = sumNs
            self.minNs = minNs
            self.maxNs = maxNs
        }

        /// An empty aggregate with no samples.
        public static let empty = Aggregate(count: 0, sumNs: 0, minNs: .max, maxNs: 0)
    }

    /// Metrics snapshot (all values consistent, taken under lock).
    ///
    /// ## Gauges
    /// Current state at snapshot time. These can go up or down.
    ///
    /// ## Counters
    /// Monotonically increasing totals since creation.
    ///
    /// ## Latency Aggregates
    /// Simple min/max/sum/count statistics (no percentiles in v1).
    ///
    /// ## Thread Safety
    /// All values are read atomically under the runtime lock,
    /// ensuring a consistent snapshot.
    public struct Metrics: Sendable, Equatable {
        // MARK: - Gauges

        /// Current number of jobs in the queue.
        public let queueDepth: Int

        /// Current number of tasks waiting for queue capacity.
        public let acceptanceWaitersDepth: Int

        /// Jobs currently running on workers.
        public let executingCount: Int

        /// Workers currently sleeping (waiting for work).
        /// Derived from `lock.worker.waiterCount`.
        public let sleepingWorkers: Int

        // MARK: - Counters

        /// Jobs successfully enqueued (includes promoted waiters).
        public let enqueuedTotal: UInt64

        /// Jobs dequeued by workers (started execution).
        public let startedTotal: UInt64

        /// Jobs finished (success or fail, after execution).
        public let completedTotal: UInt64

        /// Acceptance waiters promoted into the queue.
        public let acceptancePromotedTotal: UInt64

        /// Acceptance waiters that timed out.
        public let acceptanceTimeoutTotal: UInt64

        /// Jobs rejected immediately due to full queue (failFast policy).
        public let failFastTotal: UInt64

        /// Jobs rejected due to acceptance queue being full.
        public let overloadedTotal: UInt64

        /// Jobs cancelled via Swift task cancellation.
        public let cancelledTotal: UInt64

        // MARK: - Latency Aggregates

        /// Time from enqueue to worker start.
        public let enqueueToStart: Aggregate

        /// Time from worker start to completion.
        public let execution: Aggregate

        /// Time spent in acceptance queue (only for promoted waiters).
        /// Use with `acceptancePromotedTotal` for meaningful averages.
        public let acceptanceWait: Aggregate

        public init(
            queueDepth: Int,
            acceptanceWaitersDepth: Int,
            executingCount: Int,
            sleepingWorkers: Int,
            enqueuedTotal: UInt64,
            startedTotal: UInt64,
            completedTotal: UInt64,
            acceptancePromotedTotal: UInt64,
            acceptanceTimeoutTotal: UInt64,
            failFastTotal: UInt64,
            overloadedTotal: UInt64,
            cancelledTotal: UInt64,
            enqueueToStart: Aggregate,
            execution: Aggregate,
            acceptanceWait: Aggregate
        ) {
            self.queueDepth = queueDepth
            self.acceptanceWaitersDepth = acceptanceWaitersDepth
            self.executingCount = executingCount
            self.sleepingWorkers = sleepingWorkers
            self.enqueuedTotal = enqueuedTotal
            self.startedTotal = startedTotal
            self.completedTotal = completedTotal
            self.acceptancePromotedTotal = acceptancePromotedTotal
            self.acceptanceTimeoutTotal = acceptanceTimeoutTotal
            self.failFastTotal = failFastTotal
            self.overloadedTotal = overloadedTotal
            self.cancelledTotal = cancelledTotal
            self.enqueueToStart = enqueueToStart
            self.execution = execution
            self.acceptanceWait = acceptanceWait
        }
    }
}

// MARK: - Mutable Aggregate (Internal)

extension IO.Blocking.Threads.Aggregate {
    /// Mutable aggregate accumulator for internal use.
    ///
    /// Used by `Runtime.State` to accumulate latency metrics.
    /// The `Aggregate` struct is the immutable snapshot exposed to users.
    struct Mutable: Sendable {
        var count: UInt64 = 0
        var sumNs: UInt64 = 0
        var minNs: UInt64 = .max
        var maxNs: UInt64 = 0

        mutating func record(_ durationNs: UInt64) {
            count &+= 1
            sumNs &+= durationNs
            if durationNs < minNs { minNs = durationNs }
            if durationNs > maxNs { maxNs = durationNs }
        }

        /// Record a signed duration (for batch averages).
        mutating func record(_ durationNs: Int64) {
            guard durationNs >= 0 else { return }
            record(UInt64(bitPattern: durationNs))
        }

        func snapshot() -> IO.Blocking.Threads.Aggregate {
            IO.Blocking.Threads.Aggregate(count: count, sumNs: sumNs, minNs: minNs, maxNs: maxNs)
        }
    }
}

