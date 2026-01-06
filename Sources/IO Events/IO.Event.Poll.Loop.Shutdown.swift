//
//  IO.Event.Poll.Loop.Shutdown.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 28/12/2025.
//

public import Kernel

extension IO.Event.Poll.Loop {
    /// Namespace for shutdown-related types.
    public enum Shutdown {
        /// One-way atomic flag for coordinating poll thread shutdown.
        ///
        /// This is a type alias to `Kernel.Atomic.Flag`, providing:
        /// - `isSet`: Check if shutdown is signaled (acquiring semantics)
        /// - `set()`: Signal shutdown (releasing semantics)
        ///
        /// ## Thread Safety
        /// Safe to read from poll thread and set from selector actor.
        public typealias Flag = Kernel.Atomic.Flag
    }
}
