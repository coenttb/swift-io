//
//  IO.NonBlocking.PollLoop.Shutdown.Flag+Methods.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 28/12/2025.
//

internal import Synchronization

extension IO.NonBlocking.PollLoop.Shutdown.Flag {
    /// Check if shutdown has been requested.
    public var isSet: Bool {
        _value.load(ordering: .acquiring)
    }

    /// Request shutdown.
    public func set() {
        _value.store(true, ordering: .releasing)
    }
}
