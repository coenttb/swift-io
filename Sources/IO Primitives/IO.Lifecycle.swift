//
//  IO.Lifecycle.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 27/12/2025.
//

extension IO {
    /// Lifecycle states observable at API boundaries.
    ///
    /// These states represent conditions that affect the entire executor/lane
    /// rather than individual operations. They are separate from leaf domain
    /// errors to enforce at compile time that lifecycle cannot be confused
    /// with domain-specific failures.
    public enum Lifecycle: Sendable, Equatable {
        /// The executor or lane is shutting down.
        ///
        /// New operations are rejected immediately with this state.
        /// In-flight operations may continue to completion depending
        /// on the shutdown policy.
        case shutdownInProgress
    }
}

extension IO.Lifecycle {
    /// Coproduct separating lifecycle from leaf domain errors.
    ///
    /// This type enforces at compile time that lifecycle conditions
    /// cannot be confused with domain-specific failures. All public
    /// API boundaries that can observe shutdown use this wrapper.
    ///
    /// ## Type-Level Guarantee
    /// Leaf error enums (e.g., `IO.Blocking.Failure`, `IO.Executor.Error`)
    /// must never contain lifecycle cases. Lifecycle is only representable
    /// through this coproduct.
    ///
    /// ## Usage
    /// ```swift
    /// func run<T, E>(...) async throws(IO.Lifecycle.Error<IO.Error<E>>) -> T
    /// ```
    public enum Error<Failure: Swift.Error & Sendable>: Swift.Error, Sendable {
        /// A lifecycle condition (shutdown).
        case lifecycle(IO.Lifecycle)

        /// A leaf domain error.
        case failure(Failure)
    }
}

extension IO.Lifecycle.Error: Equatable where Failure: Equatable {}
