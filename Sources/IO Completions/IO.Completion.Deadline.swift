//
//  IO.Completion.Deadline.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 31/12/2025.
//

public import Dimension
public import Kernel

extension IO.Completion {
    /// A point in time for timeout calculations.
    ///
    /// Deadlines are used instead of durations to avoid drift
    /// when poll is interrupted and restarted.
    ///
    /// Delegates to `Kernel.Time.Deadline` for monotonic time handling.
    /// Access underlying API via `.rawValue`.
    public typealias Deadline = Tagged<IO.Completion, Kernel.Time.Deadline>
}
