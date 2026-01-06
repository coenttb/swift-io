//
//  IO.Event.Channel.HalfClose.State.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 29/12/2025.
//

extension IO.Event.Channel.HalfClose {
    /// Half-close state of a channel.
    ///
    /// Tracks which directions of the channel have been closed.
    /// Uses OptionSet since read and write are independent flags.
    struct State: OptionSet, Sendable {
        let rawValue: UInt8

        /// Read direction is closed (EOF received or shutdown.read() called).
        static let read = State(rawValue: 1 << 0)

        /// Write direction is closed (shutdown.write() called).
        static let write = State(rawValue: 1 << 1)
    }
}
