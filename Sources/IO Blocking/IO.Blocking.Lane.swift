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
    ///   `run()` throws `.cancelled` immediately without enqueuing.
    /// - **After acceptance**: If `guaranteesRunOnceEnqueued` is true, the job runs
    ///   to completion. The caller may observe `.cancelled` upon return,
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

        // The run implementation.
        // - Operation closure returns boxed value (never throws)
        // - Lane throws only Failure for infrastructure failures
        private let _run:
            @Sendable @concurrent (
                Deadline?,
                @Sendable @escaping () -> UnsafeMutableRawPointer  // Returns boxed value
            ) async throws(Failure) -> UnsafeMutableRawPointer

        private let _shutdown: @Sendable @concurrent () async -> Void

        package init(
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

        // MARK: - Core Primitive (Result-returning)

        /// Executes a Result-returning operation.
        ///
        /// Core primitive - preserves typed error through Result without casting.
        /// Internal to force callers through the typed-throws run wrapper.
        /// Lane only throws Failure for infrastructure failures.
        @concurrent
        internal func runResult<T: Sendable, E: Swift.Error & Sendable>(
            deadline: Deadline?,
            _ operation: @Sendable @escaping () -> Result<T, E>
        ) async throws(Failure) -> Result<T, E> {
            let ptr = try await _run(deadline) {
                let result = operation()
                return IO.Blocking.Box.make(result)
            }
            return IO.Blocking.Box.take(ptr)
        }

        // MARK: - Convenience (Typed-Throws)

        /// Executes a typed-throwing operation, returning Result.
        ///
        /// ## Quarantined Cast (Swift Embedded Safe)
        /// Swift currently infers error as `any Error` even when operation `throws(E)`.
        /// We use a single, localized `as?` cast to recover `E` without introducing
        /// existentials into storage or API boundaries. This is the ONLY cast in the
        /// module and is acceptable for Embedded compatibility.
        @concurrent
        public func run<T: Sendable, E: Swift.Error & Sendable>(
            deadline: Deadline?,
            _ operation: @Sendable @escaping () throws(E) -> T
        ) async throws(Failure) -> Result<T, E> {
            try await runResult(deadline: deadline) {
                do {
                    return .success(try operation())
                } catch {
                    // Quarantined cast to recover E from `any Error`.
                    // This is the only cast in the module - do not add others.
                    guard let e = error as? E else {
                        // Contract: `operation` is declared as `throws(E)` and must be observed as `E`.
                        // If this fails, there is no safe recovery (we cannot manufacture `E`).
                        // Terminate deliberately to surface invariant violations.
                        fatalError(
                            "Lane.run: invariant violated - expected \(E.self), got \(type(of: error))"
                        )
                    }
                    return .failure(e)
                }
            }
        }

        // MARK: - Convenience (Non-throwing)

        /// Executes a non-throwing operation, returning value directly.
        @concurrent
        public func run<T: Sendable>(
            deadline: Deadline?,
            _ operation: @Sendable @escaping () -> T
        ) async throws(Failure) -> T {
            let ptr = try await _run(deadline) {
                let result = operation()
                return IO.Blocking.Box.makeValue(result)
            }
            return IO.Blocking.Box.takeValue(ptr)
        }

        @concurrent
        public func shutdown() async {
            await _shutdown()
        }

    }
}
