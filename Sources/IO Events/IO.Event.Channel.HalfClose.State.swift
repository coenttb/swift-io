//
//  IO.Event.Channel.HalfClose.State.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 29/12/2025.
//

extension IO.Event.Channel.HalfClose {
    /// Half-close state of a channel.
    ///
    /// Tracks which directions of the channel are open for I/O.
    enum State: Sendable {
        /// Both directions open.
        case open
        /// Read direction closed (EOF received or shutdownRead called).
        case readClosed
        /// Write direction closed (shutdownWrite called).
        case writeClosed
        /// Both directions closed.
        case closed
    }
}
