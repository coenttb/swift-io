//
//  IO.Blocking.Lane.Abandoning.Worker.Execution.Result.swift
//  swift-io
//
//  Result of executing a job with watchdog.
//

extension IO.Blocking.Lane.Abandoning.Worker.Execution {
    /// Result of job execution.
    enum Result {
        case completed
        case abandoned  // Worker was timed out and abandoned
        case cancelled
    }
}
