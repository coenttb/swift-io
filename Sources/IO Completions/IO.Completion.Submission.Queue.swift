//
//  IO.Completion.Submission.Queue.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 31/12/2025.
//

public import Dimension
public import Runtime

extension IO.Completion {
    /// Namespace for submission-related types.
    public enum Submission {}
}

extension IO.Completion.Submission {
    /// Thread-safe MPSC queue for actor → poll thread submission handoff.
    ///
    /// Delegates to `Runtime.Mutex.Queue` for thread-safe buffering.
    /// Access underlying API via `.rawValue`.
    public typealias Queue = Tagged<IO.Completion.Submission, Runtime.Mutex.Queue<IO.Completion.Operation.Storage>>
}
