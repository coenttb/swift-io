//
//  IO.Completion.Submission.Queue.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 31/12/2025.
//

public import Synchronization
public import Dimension
public import Buffer

extension IO.Completion.Submission {
    /// Thread-safe MPSC queue for actor → poll thread submission handoff.
    ///
    /// Delegates to `Shared<Mutex<Deque<T>>>` for thread-safe buffering.
    /// Access underlying API via `.rawValue`.
    public typealias Queue = Tagged<IO.Completion.Submission, Shared<Mutex<Deque<IO.Completion.Operation.Storage>>>>
}
