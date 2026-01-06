//
//  IO.Blocking.Lane.Abandoning.Error.swift
//  swift-io
//
//  Errors specific to the abandoning lane.
//

public import IO_Blocking_Threads

extension IO.Blocking.Lane.Abandoning {
    /// Errors specific to the abandoning lane.
    ///
    /// These errors are distinct from `IO.Blocking.Lane.Error` because they
    /// represent failure modes specific to abandon-on-timeout semantics.
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
        /// This indicates too many hung operations have accumulated.
        /// Consider increasing `maxWorkers` or investigating the hung operations.
        case maxWorkersReached

        /// A lane-level error (queueFull, overloaded, etc.).
        ///
        /// Wraps the underlying `IO.Blocking.Lane.Error` for specific handling.
        case lane(IO.Blocking.Lane.Error)
    }
}
