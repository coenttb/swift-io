//
//  IO.Event.Armed.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 28/12/2025.
//

extension IO.Event {
    /// Phase indicating an armed waiter awaiting readiness.
    ///
    /// A token in this phase can be:
    /// - Modified with `modify()` to change interests
    /// - Deregistered with `deregister()` to remove from selector
    /// - Cancelled with `cancel()` to abort the wait
    public enum Armed {}
}
