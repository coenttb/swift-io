//
//  IO.Event.Registering.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 28/12/2025.
//

extension IO.Event {
    /// Phase indicating a freshly registered descriptor.
    ///
    /// A token in this phase can be:
    /// - Armed with `arm()` to wait for readiness
    /// - Cancelled with `cancel()` before arming
    public enum Registering {}
}
