//
//  IO.NonBlocking.PollLoop.Shutdown.Flag.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 28/12/2025.
//

import Synchronization

extension IO.NonBlocking.PollLoop.Shutdown {
    /// Atomic shutdown flag for coordinating poll thread shutdown.
    ///
    /// This is a simple atomic boolean that can be read from the poll
    /// thread and set from the selector actor.
    public final class Flag: Sendable {
        let _value: Atomic<Bool>

        /// Creates a new shutdown flag (initially false).
        public init() {
            self._value = Atomic(false)
        }
    }
}
