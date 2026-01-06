//
//  IO.Blocking.Lane.Test.Error.swift
//  swift-io
//
//  Test-specific errors for the fault-tolerant test lane.
//

public import IO_Blocking_Threads

extension IO.Blocking.Lane.Test {
    /// Errors specific to the test lane.
    ///
    /// These errors are distinct from `IO.Blocking.Lane.Error` because they
    /// represent test-specific failure modes that don't apply to production lanes.
    public enum Error: Swift.Error, Sendable, Equatable {
        /// The operation exceeded the execution timeout.
        ///
        /// The operation was abandoned on a detached thread and may still be running.
        /// Side effects may have occurred or may still occur after this error.
        case executionTimedOut

        /// No workers available to accept new work.
        ///
        /// This occurs when:
        /// - All initial workers have been abandoned due to timeouts
        /// - The abandoned count has reached `maxWorkers`
        /// - No replacement workers can be spawned
        ///
        /// This indicates the test suite has accumulated too many hung operations.
        /// Consider increasing `maxWorkers` or investigating the hung operations.
        case maxWorkersReached

        /// A lane-level error (queueFull, overloaded, etc.).
        ///
        /// Wraps the underlying `IO.Blocking.Lane.Error` for test-specific handling.
        case lane(IO.Blocking.Lane.Error)
    }
}
