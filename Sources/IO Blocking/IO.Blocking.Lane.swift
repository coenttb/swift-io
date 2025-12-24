//
//  IO.Blocking.Lane.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 24/12/2025.
//

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
        private let _run:
            @Sendable (
                Deadline?,
                @Sendable @escaping () -> UnsafeMutableRawPointer  // Returns boxed value
            ) async throws(Failure) -> UnsafeMutableRawPointer

        private let _shutdown: @Sendable () async -> Void

        public init(
            capabilities: Capabilities,
            run:
                @escaping @Sendable (
                    Deadline?,
                    @Sendable @escaping () -> UnsafeMutableRawPointer
                ) async throws(Failure) -> UnsafeMutableRawPointer,
            shutdown: @escaping @Sendable () async -> Void
        ) {
            self.capabilities = capabilities
            self._run = run
            self._shutdown = shutdown
        }

        // MARK: - Core Primitive (Result-returning)

        /// Execute a Result-returning operation.
        ///
        /// This is the core primitive. The operation produces a `Result<T, E>` directly,
        /// preserving the typed error without any casting or existentials.
        ///
        /// Internal to force callers through the typed-throws `run` wrapper.
        /// Lane only throws `Failure` for infrastructure failures.
        internal func runResult<T: Sendable, E: Swift.Error & Sendable>(
            deadline: Deadline?,
            _ operation: @Sendable @escaping () -> Result<T, E>
        ) async throws(Failure) -> Result<T, E> {
            let ptr = try await _run(deadline) {
                let result = operation()
                return Self.box(result)
            }
            return Self.unbox(ptr)
        }

        // MARK: - Convenience (Typed-Throws)

        /// Execute a typed-throwing operation, returning Result.
        ///
        /// This convenience wrapper converts `throws(E) -> T` to `() -> Result<T, E>`.
        ///
        /// ## Quarantined Cast (Swift Embedded Safe)
        /// Swift currently infers `error` as `any Error` even when `operation` throws(E).
        /// We use a single, localized `as?` cast to recover E without introducing
        /// existentials into storage or API boundaries. This is the ONLY cast in the
        /// module and is acceptable for Embedded compatibility.
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

        // MARK: - Convenience (Non-throwing)

        /// Execute a non-throwing operation, returning value directly.
        public func run<T: Sendable>(
            deadline: Deadline?,
            _ operation: @Sendable @escaping () -> T
        ) async throws(Failure) -> T {
            let ptr = try await _run(deadline) {
                let result = operation()
                return Self.boxValue(result)
            }
            return Self.unboxValue(ptr)
        }

        public func shutdown() async {
            await _shutdown()
        }

        // MARK: - Boxing Helpers

        /// ## Boxing Ownership Rules
        ///
        /// **Invariant:** Exactly one party allocates, exactly one party frees.
        ///
        /// - **Allocation:** The operation closure allocates via `box()` inside the lane worker
        /// - **Deallocation:** The caller deallocates via `unbox()` after receiving pointer
        ///
        /// **Cancellation/Shutdown Safety:**
        /// - If a job is enqueued but never executed (shutdown), the job is dropped
        ///   but no pointer was allocated yet (allocation happens inside job execution)
        /// - If a job is executed, the pointer is always returned to the continuation
        /// - If continuation is resumed with failure, no pointer was allocated
        ///
        /// **Never allocate before enqueue.** Allocation happens inside the job body.

        private static func box<T, E: Swift.Error>(
            _ result: Result<T, E>
        ) -> UnsafeMutableRawPointer {
            let ptr = UnsafeMutablePointer<Result<T, E>>.allocate(capacity: 1)
            ptr.initialize(to: result)
            return UnsafeMutableRawPointer(ptr)
        }

        private static func unbox<T, E: Swift.Error>(_ ptr: UnsafeMutableRawPointer) -> Result<T, E> {
            let typed = ptr.assumingMemoryBound(to: Result<T, E>.self)
            let result = typed.move()
            typed.deallocate()
            return result
        }

        private static func boxValue<T>(_ value: T) -> UnsafeMutableRawPointer {
            let ptr = UnsafeMutablePointer<T>.allocate(capacity: 1)
            ptr.initialize(to: value)
            return UnsafeMutableRawPointer(ptr)
        }

        private static func unboxValue<T>(_ ptr: UnsafeMutableRawPointer) -> T {
            let typed = ptr.assumingMemoryBound(to: T.self)
            let result = typed.move()
            typed.deallocate()
            return result
        }
    }
}
