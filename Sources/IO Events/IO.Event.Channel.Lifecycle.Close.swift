//
//  IO.Event.Channel.Lifecycle.Close.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 29/12/2025.
//

extension IO.Event.Channel.Lifecycle {
    /// Accessor for close operations.
    struct Close {
        let lifecycle: IO.Event.Channel.Lifecycle

        /// Transition to read-closed state.
        func read() async {
            await lifecycle.closeRead()
        }

        /// Transition to write-closed state.
        func write() async {
            await lifecycle.closeWrite()
        }

        /// Transition to fully closed state.
        /// - Returns: `true` if already closed (no-op), `false` if transition occurred.
        func callAsFunction() async -> Bool {
            await lifecycle.closeAll()
        }
    }
}
