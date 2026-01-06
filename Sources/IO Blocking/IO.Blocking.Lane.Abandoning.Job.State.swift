//
//  IO.Blocking.Lane.Abandoning.Job.State.swift
//  swift-io
//
//  Atomic state for job lifecycle.
//

import Synchronization

extension IO.Blocking.Lane.Abandoning.Job {
    /// Atomic state for CAS discipline.
    enum State: UInt8, AtomicRepresentable {
        case pending = 0
        case running = 1
        case completed = 2
        case timedOut = 3
        case cancelled = 4
        case failed = 5
    }
}
