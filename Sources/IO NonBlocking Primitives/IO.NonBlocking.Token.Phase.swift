//
//  IO.NonBlocking.Token.Phase.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 28/12/2025.
//

extension IO.NonBlocking {
    /// Phase indicating a freshly registered descriptor.
    ///
    /// A token in this phase can be:
    /// - Armed with `arm()` to wait for readiness
    /// - Cancelled with `cancel()` before arming
    public enum Registering {}

    /// Phase indicating an armed waiter awaiting readiness.
    ///
    /// A token in this phase can be:
    /// - Modified with `modify()` to change interests
    /// - Deregistered with `deregister()` to remove from selector
    /// - Cancelled with `cancel()` to abort the wait
    public enum Armed {}

    /// Phase indicating a completed operation.
    ///
    /// A token in this phase cannot be used for further operations.
    /// The registration has either:
    /// - Received a readiness event
    /// - Been cancelled
    /// - Been deregistered
    public enum Completed {}
}
