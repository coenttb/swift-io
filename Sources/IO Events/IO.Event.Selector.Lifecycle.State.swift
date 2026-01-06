//
//  IO.Event.Selector.Lifecycle.State.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 28/12/2025.
//

extension IO.Event.Selector.Lifecycle {
    /// Lifecycle state of the selector.
    enum State {
        case running
        case shuttingDown
        case shutdown
    }
}
