//
//  IO.Blocking.Lane.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 24/12/2025.
//

// NOTE: Lane is an execution backend abstraction.
// Do not assume Threads is the only implementation.
// Future: may be backed by platform executors (swift-platform-executors).

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
        /// - Lane throws only Failure for infrastructure failures
        package let _run:
            @Sendable @concurrent (
                Deadline?,
                @Sendable @escaping () -> UnsafeMutableRawPointer  // Returns boxed value
            ) async throws(Failure) -> UnsafeMutableRawPointer

        private let _shutdown: @Sendable @concurrent () async -> Void

        public init(
            capabilities: Capabilities,
            run:
                @escaping @Sendable @concurrent (
                    Deadline?,
                    @Sendable @escaping () -> UnsafeMutableRawPointer
                ) async throws(Failure) -> UnsafeMutableRawPointer,
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
    /// Lane only throws `Failure` for infrastructure failures.
    @concurrent
    internal func runResult<T: Sendable, E: Swift.Error & Sendable>(
        deadline: IO.Blocking.Deadline?,
        _ operation: @Sendable @escaping () -> Result<T, E>
    ) async throws(IO.Blocking.Failure) -> Result<T, E> {
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
    ) async throws(IO.Blocking.Failure) -> Result<T, E> {
        try await runResult(deadline: deadline) {
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
    ) async throws(IO.Blocking.Failure) -> T {
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
