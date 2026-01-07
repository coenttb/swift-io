//
//  IO.run.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 07/01/2026.
//

public import IO_Blocking

extension IO {
    /// Execute non-throwing blocking work on a lane.
    ///
    /// This is the simplest entry point for blocking I/O. The system
    /// uses dedicated OS threads to prevent blocking Swift's cooperative
    /// thread pool.
    ///
    /// ## Usage
    ///
    /// ```swift
    /// // Simple blocking work on shared lane
    /// let hash = try await IO.run {
    ///     computeExpensiveHash(data)
    /// }
    ///
    /// // With deadline
    /// let data = try await IO.run(deadline: .after(.seconds(5))) {
    ///     FileHandle.read(path)
    /// }
    ///
    /// // Custom lane
    /// let lane = IO.Lane.threads(.init(workers: 4))
    /// let result = try await IO.run(on: lane) {
    ///     expensiveComputation()
    /// }
    /// ```
    ///
    /// ## Error Handling
    ///
    /// ```swift
    /// do {
    ///     let value = try await IO.run { compute() }
    /// } catch {
    ///     switch error {
    ///     case .cancelled: // task was cancelled
    ///     case .timeout: // deadline expired
    ///     case .shutdown: // lane is shutting down
    ///     case .overloaded: // lane capacity exhausted
    ///     }
    /// }
    /// ```
    ///
    /// - Parameters:
    ///   - lane: The lane to execute on (default: `.shared`).
    ///   - deadline: Optional deadline for acceptance.
    ///   - operation: The non-throwing blocking operation.
    /// - Returns: The operation result.
    /// - Throws: `IO.Lane.Error` for lane failures.
    @inlinable
    public static func run<T: Sendable>(
        on lane: IO.Lane = .shared,
        deadline: IO.Deadline? = nil,
        _ operation: @Sendable @escaping () -> T
    ) async throws(IO.Lane.Error) -> T {
        do {
            return try await lane._backing.run(deadline: deadline, operation)
        } catch {
            throw IO.Lane.Error(from: error)
        }
    }

    /// Execute throwing blocking work on a lane.
    ///
    /// For operations that can throw, both lane errors and operation errors
    /// are captured in the `IO.Failure.Work` envelope.
    ///
    /// ## Usage
    ///
    /// ```swift
    /// let result = try await IO.run(deadline: .after(.seconds(5))) {
    ///     try socket.connect()
    /// }
    /// ```
    ///
    /// ## Error Handling
    ///
    /// ```swift
    /// do {
    ///     let value = try await IO.run { try riskyOperation() }
    /// } catch {
    ///     switch error {
    ///     case .domain(.timeout): // lane timeout
    ///     case .domain(.cancelled): // task cancelled
    ///     case .operation(let e): // operation threw
    ///     }
    /// }
    /// ```
    ///
    /// - Parameters:
    ///   - lane: The lane to execute on (default: `.shared`).
    ///   - deadline: Optional deadline for acceptance.
    ///   - operation: The throwing blocking operation.
    /// - Returns: The operation result.
    /// - Throws: `IO.Failure.Work<IO.Lane.Error, E>` for lane or operation failures.
    @inlinable
    public static func run<T: Sendable, E: Swift.Error & Sendable>(
        on lane: IO.Lane = .shared,
        deadline: IO.Deadline? = nil,
        _ operation: @Sendable @escaping () throws(E) -> T
    ) async throws(IO.Failure.Work<IO.Lane.Error, E>) -> T {
        let result: Result<T, E>
        do {
            result = try await lane._backing.run(deadline: deadline, operation)
        } catch {
            throw .domain(IO.Lane.Error(from: error))
        }
        switch result {
        case .success(let value):
            return value
        case .failure(let error):
            throw .operation(error)
        }
    }
}
