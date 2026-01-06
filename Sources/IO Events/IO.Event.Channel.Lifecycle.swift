//
//  IO.Event.Channel.Lifecycle.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 29/12/2025.
//

extension IO.Event.Channel {
    /// Actor for half-close state synchronization.
    ///
    /// This actor manages only the lifecycle state transitions.
    /// I/O operations and token management are handled by Channel directly.
    actor Lifecycle {
        private var state: HalfClose.State = []

        var isReadClosed: Bool {
            state.contains(.read)
        }

        var isWriteClosed: Bool {
            state.contains(.write)
        }

        var isClosed: Bool {
            state.contains([.read, .write])
        }

        /// Accessor for close operations.
        nonisolated var close: Close { Close(lifecycle: self) }

        /// Internal: Transition to read-closed state.
        func closeRead() {
            state.insert(.read)
        }

        /// Internal: Transition to write-closed state.
        func closeWrite() {
            state.insert(.write)
        }

        /// Internal: Transition to fully closed state.
        /// - Returns: `true` if already closed (no-op), `false` if transition occurred.
        func closeAll() -> Bool {
            let wasClosed = isClosed
            state = [.read, .write]
            return wasClosed
        }
    }
}
