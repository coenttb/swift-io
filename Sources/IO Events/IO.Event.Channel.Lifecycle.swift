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
        private var state: HalfClose.State = .open

        var isReadClosed: Bool {
            switch state {
            case .readClosed, .closed: return true
            case .open, .writeClosed: return false
            }
        }

        var isWriteClosed: Bool {
            switch state {
            case .writeClosed, .closed: return true
            case .open, .readClosed: return false
            }
        }

        var isClosed: Bool {
            state == .closed
        }

        /// Accessor for close operations.
        nonisolated var close: Close { Close(lifecycle: self) }

        /// Internal: Transition to read-closed state.
        func closeRead() {
            switch state {
            case .open:
                state = .readClosed
            case .writeClosed:
                state = .closed
            case .readClosed, .closed:
                break  // Already done
            }
        }

        /// Internal: Transition to write-closed state.
        func closeWrite() {
            switch state {
            case .open:
                state = .writeClosed
            case .readClosed:
                state = .closed
            case .writeClosed, .closed:
                break  // Already done
            }
        }

        /// Internal: Transition to fully closed state.
        /// - Returns: `true` if already closed (no-op), `false` if transition occurred.
        func closeAll() -> Bool {
            if state == .closed {
                return true
            }
            state = .closed
            return false
        }
    }
}
