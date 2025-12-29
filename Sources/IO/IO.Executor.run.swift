//
//  IO.Executor.run.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 28/12/2025.
//

extension IO.Executor {
    /// Execute blocking work directly on a lane without handle coordination.
    ///
    /// ## Design
    ///
    /// This is the fast path for stateless operations. Unlike `Pool.run()`, this
    /// method bypasses the Pool actor entirely, eliminating actor serialization
    /// overhead for operations that don't need handle coordination.
    ///
    /// ## When to Use
    ///
    /// Use this method when:
    /// - The operation doesn't require exclusive access to a registered handle
    /// - You want maximum throughput for stateless blocking work
    /// - You're performing bulk operations that can run independently
    ///
    /// ## Cancellation Semantics
    ///
    /// Same as `Pool.run()`:
    /// - Cancellation before acceptance → `.cancelled`
    /// - Cancellation after acceptance → operation completes, then `.cancelled`
    ///
    /// ## Usage
    ///
    /// ```swift
    /// let lane = IO.Blocking.Lane.threads()
    ///
    /// let result = try await IO.Executor.run(on: lane) {
    ///     // Blocking work here
    ///     return computeSomething()
    /// }
    /// ```
    ///
    /// - Parameters:
    ///   - lane: The lane to execute on.
    ///   - deadline: Optional deadline for acceptance (not execution).
    ///   - operation: The blocking operation to execute.
    /// - Returns: The result of the operation.
    /// - Throws: `IO.Lifecycle.Error<IO.Error<E>>` with lifecycle or operation errors.
    public static func run<T: Sendable, E: Swift.Error & Sendable>(
        on lane: IO.Blocking.Lane,
        deadline: IO.Blocking.Deadline? = nil,
        _ operation: @Sendable @escaping () throws(E) -> T
    ) async throws(IO.Lifecycle.Error<IO.Error<E>>) -> T {
        // Fast-path: if already cancelled, skip lane submission entirely
        if Task.isCancelled {
            throw .cancelled
        }

        // Lane.run throws(Failure) and returns Result<T, E>
        let result: Result<T, E>
        do {
            result = try await lane.run(deadline: deadline, operation)
        } catch {
            throw IO.Lifecycle.Error(error)
        }
        switch result {
        case .success(let value):
            return value
        case .failure(let error):
            throw .failure(.leaf(error))
        }
    }

    /// Execute non-throwing blocking work directly on a lane.
    ///
    /// This is a convenience overload for operations that don't throw.
    ///
    /// - Parameters:
    ///   - lane: The lane to execute on.
    ///   - deadline: Optional deadline for acceptance (not execution).
    ///   - operation: The non-throwing blocking operation to execute.
    /// - Returns: The result of the operation.
    /// - Throws: `IO.Lifecycle.Error<IO.Blocking.Error>` for lane failures only.
    public static func run<T: Sendable>(
        on lane: IO.Blocking.Lane,
        deadline: IO.Blocking.Deadline? = nil,
        _ operation: @Sendable @escaping () -> T
    ) async throws(IO.Lifecycle.Error<IO.Blocking.Error>) -> T {
        // Fast-path: if already cancelled, skip lane submission entirely
        if Task.isCancelled {
            throw .cancelled
        }

        do {
            return try await lane.run(deadline: deadline, operation)
        } catch {
            throw IO.Lifecycle.Error(error)
        }
    }
}
