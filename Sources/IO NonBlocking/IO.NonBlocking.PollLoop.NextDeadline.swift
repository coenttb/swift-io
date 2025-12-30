//
//  IO.NonBlocking.PollLoop.NextDeadline.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 30/12/2025.
//

import Synchronization

extension IO.NonBlocking.PollLoop {
    /// Atomic next poll deadline for coordinating timeout between selector and poll thread.
    ///
    /// The selector writes the earliest deadline from its heap, and the poll thread
    /// reads it each iteration to determine the poll timeout.
    ///
    /// ## Semantics
    /// - `UInt64.max` means "no deadline" (poll blocks indefinitely or until events)
    /// - Any other value is nanoseconds since monotonic epoch
    ///
    /// ## Thread Safety
    /// `Sendable` because it provides internal synchronization via `Atomic`.
    public final class NextDeadline: Sendable {
        let _value: Atomic<UInt64>

        /// Creates a new next deadline (initially .max = no deadline).
        public init() {
            self._value = Atomic(UInt64.max)
        }
    }
}

// MARK: - Methods

extension IO.NonBlocking.PollLoop.NextDeadline {
    /// The current next deadline in nanoseconds.
    ///
    /// Returns `UInt64.max` if there is no deadline.
    public var nanoseconds: UInt64 {
        _value.load(ordering: .acquiring)
    }

    /// Updates the next deadline.
    ///
    /// - Parameter nanoseconds: The new deadline in nanoseconds, or `UInt64.max` for no deadline.
    public func store(_ nanoseconds: UInt64) {
        _value.store(nanoseconds, ordering: .releasing)
    }

    /// Converts to a `Deadline?` for use with `driver.poll()`.
    ///
    /// Returns `nil` if the value is `.max` (no deadline).
    public var asDeadline: IO.NonBlocking.Deadline? {
        let ns = nanoseconds
        if ns == .max {
            return nil
        }
        return IO.NonBlocking.Deadline(nanoseconds: ns)
    }
}
