//
//  IO.Event.Selector.Registration.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 28/12/2025.
//

extension IO.Event.Selector {
    /// A registered descriptor.
    struct Registration {
        let descriptor: Int32
        var interest: IO.Event.Interest
    }
}
