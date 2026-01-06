//
//  IO.Blocking.Lane.Abandoning.swift
//  swift-io
//
//  Fault-tolerant lane that can abandon hung operations.
//

import Synchronization

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

extension IO.Blocking.Lane {
    /// A fault-tolerant lane that can abandon hung operations.
    ///
    /// ## Purpose
    /// Prevents a single hung synchronous operation from wedging the entire system.
    /// When an operation exceeds its timeout, the caller resumes with an error while
    /// the operation continues on an abandoned thread.
    ///
    /// This implements what Polly (.NET) calls "pessimistic timeout": the caller
    /// "walks away" from an unresponsive operation without cancelling it.
    ///
    /// ## Warning: Production Use
    /// This lane is suitable for isolating uncooperative third-party code that offers
    /// no cancellation mechanism. However, be aware of the implications:
    /// - Abandoned operations continue consuming resources (CPU, memory, file handles)
    /// - Side effects from abandoned operations may complete after the caller has moved on
    /// - Accumulated abandoned threads can exhaust system resources
    ///
    /// For most production scenarios, prefer cooperative cancellation with
    /// `Execution.Semantics.guaranteed` or `.bestEffort`.
    ///
    /// ## Semantics: Abandon, Not Cancel
    /// - Timeout resumes the caller but does NOT cancel the operation
    /// - The abandoned operation may continue running on a detached thread
    /// - Side effects can outlive the caller
    /// - Only suitable for scenarios with "pure-ish" or idempotent operations
    ///
    /// ## Usage
    /// ```swift
    /// let abandoning = IO.Blocking.Lane.abandoning(.init(
    ///     execution: .init(timeout: .seconds(5))
    /// ))
    ///
    /// let result = try await abandoning.lane.run(deadline: nil) {
    ///     // This operation will be abandoned if it takes > 5 seconds
    ///     someBlockingOperation()
    /// }
    ///
    /// // Check metrics
    /// let metrics = abandoning.metrics()
    /// print("Abandoned: \(metrics.workers.abandoned)")
    ///
    /// await abandoning.lane.shutdown()
    /// ```
    ///
    /// - SeeAlso: [Polly Pessimistic Timeout](https://github.com/App-vNext/Polly/wiki/Timeout)
    /// - SeeAlso: [Hystrix Thread Isolation](https://github.com/Netflix/Hystrix/wiki/How-it-Works)
    public struct Abandoning: Sendable {
        /// The underlying lane.
        public let lane: IO.Blocking.Lane

        /// The runtime (internal, for metrics access).
        private let runtime: Runtime

        /// Creates an abandoning lane with the given options.
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
    /// Creates a fault-tolerant lane that abandons hung operations.
    ///
    /// Use this lane when operations may hang indefinitely and you need the caller
    /// to resume after a timeout. The lane will abandon hung operations after the
    /// configured timeout, spawning replacement workers as needed.
    ///
    /// This implements "pessimistic timeout" semantics: the caller walks away from
    /// the operation, but the operation itself is not cancelled.
    ///
    /// - Parameter options: Configuration options.
    /// - Returns: An abandoning wrapper containing the lane and metrics access.
    ///
    /// - SeeAlso: [Polly Pessimistic Timeout](https://github.com/App-vNext/Polly/wiki/Timeout)
    public static func abandoning(_ options: Abandoning.Options = .init()) -> Abandoning {
        Abandoning(options: options)
    }
}
