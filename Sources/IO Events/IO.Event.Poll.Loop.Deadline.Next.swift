//
//  IO.Event.Poll.Loop.Deadline.Next.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 30/12/2025.
//

import Kernel

extension IO.Event.Poll.Loop {
    /// Namespace for deadline-related types.
    public enum Deadline {}
}

extension IO.Event.Poll.Loop.Deadline {
    /// Atomic next poll deadline for coordinating timeout between selector and poll thread.
    ///
    /// Delegates to `Kernel.Time.Deadline.Next`.
    public typealias Next = Kernel.Time.Deadline.Next
}

// MARK: - IO-specific extension

extension Kernel.Time.Deadline.Next {
    /// Converts to `IO.Event.Deadline` for use with `driver.poll()`.
    ///
    /// Returns `nil` if no deadline is set.
    public var asDeadline: IO.Event.Deadline? {
        guard let deadline = value else { return nil }
        return IO.Event.Deadline(deadline)
    }
}
