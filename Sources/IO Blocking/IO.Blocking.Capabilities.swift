//
//  IO.Blocking.Capabilities.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 24/12/2025.
//

extension IO.Blocking {
    /// Capabilities declared by a lane.
    ///
    /// Capabilities are truth declarations - lanes must not claim capabilities
    /// they cannot reliably provide. Core code adapts behavior based on these flags.
    public struct Capabilities: Sendable, Equatable {
        /// Whether the lane executes on dedicated OS threads.
        ///
        /// When true:
        /// - Blocking syscalls do not interfere with Swift's cooperative pool.
        /// - The executor can safely schedule long-blocking operations.
        ///
        /// When false:
        /// - The lane may use Swift's cooperative pool or other shared resources.
        /// - Sustained blocking may affect unrelated async work.
        public var executesOnDedicatedThreads: Bool

        /// Whether accepted jobs are guaranteed to run.
        ///
        /// When true:
        /// - Once a job is accepted (run() doesn't throw before enqueue),
        ///   it will execute to completion regardless of caller cancellation.
        /// - Enables safe mutation semantics: the operation runs, caller may
        ///   just not observe the result.
        ///
        /// When false:
        /// - Accepted jobs may be dropped on shutdown or cancellation.
        /// - Callers cannot rely on "run once accepted" semantics.
        public var guaranteesRunOnceEnqueued: Bool

        /// Creates capabilities with explicit values.
        public init(
            executesOnDedicatedThreads: Bool,
            guaranteesRunOnceEnqueued: Bool
        ) {
            self.executesOnDedicatedThreads = executesOnDedicatedThreads
            self.guaranteesRunOnceEnqueued = guaranteesRunOnceEnqueued
        }
    }
}
