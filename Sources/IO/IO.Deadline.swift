//
//  IO.Deadline.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 07/01/2026.
//

public import IO_Blocking

extension IO {
    /// A deadline for lane acceptance.
    ///
    /// Deadlines bound the time a caller waits for queue capacity or acceptance.
    /// They do not interrupt syscalls once executing.
    ///
    /// ## Usage
    /// ```swift
    /// try await IO.run(deadline: .after(.seconds(5))) {
    ///     try expensiveOperation()
    /// }
    /// ```
    ///
    /// ## Implementation
    /// This is a typealias to `IO.Blocking.Deadline`, which wraps a monotonic clock
    /// instant from swift-time-standard.
    public typealias Deadline = IO.Blocking.Deadline
}
