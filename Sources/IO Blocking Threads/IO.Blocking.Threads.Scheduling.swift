//
//  IO.Blocking.Threads.Scheduling.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 06/01/2026.
//

extension IO.Blocking.Threads {
    /// Job scheduling order for the thread pool.
    ///
    /// ## FIFO (First-In-First-Out)
    /// Jobs are processed in submission order. Provides fair scheduling
    /// where no job can be indefinitely delayed by newer jobs.
    ///
    /// ## LIFO (Last-In-First-Out)
    /// Most recently submitted jobs are processed first. Provides better
    /// cache locality for CPU-bound work (10-20% improvement typical)
    /// because the most recent job's data is likely still in cache.
    ///
    /// ## When to Use LIFO
    /// - Short-lived, homogeneous tasks
    /// - CPU-bound work where cache locality matters
    /// - Workloads where all tasks have similar priority
    ///
    /// ## When NOT to Use LIFO
    /// - Long-running tasks (older tasks may starve)
    /// - Fairness-critical workloads
    /// - Tasks with deadlines or SLAs
    public enum Scheduling: Sendable, Equatable {
        /// First-In-First-Out (default). Fair scheduling.
        case fifo

        /// Last-In-First-Out. Better cache locality, but can starve older tasks.
        case lifo
    }
}
