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

        /// The execution guarantee this lane provides for accepted jobs.
        ///
        /// See ``IO.Blocking.Execution.Semantics`` for the full lattice of guarantees.
        public var executionSemantics: Execution.Semantics

        /// Creates capabilities with explicit values.
        public init(
            executesOnDedicatedThreads: Bool,
            executionSemantics: Execution.Semantics
        ) {
            self.executesOnDedicatedThreads = executesOnDedicatedThreads
            self.executionSemantics = executionSemantics
        }
    }
}
