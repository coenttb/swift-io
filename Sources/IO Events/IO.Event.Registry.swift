//
//  IO.Event.Registration.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 28/12/2025.
//

import Synchronization
import Kernel

extension IO.Event {
    /// Namespace for registration-related types.
    typealias Registry = Synchronization.Mutex<[Int32: [IO.Event.ID: IO.Event.Registration.Entry]]>
}

extension IO.Event.Registry {
    static let shared = IO.Event.Registry([:])
}
