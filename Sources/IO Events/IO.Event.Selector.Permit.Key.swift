//
//  IO.Event.Selector.Permit.Key.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 28/12/2025.
//

extension IO.Event.Selector.Permit {
    /// Key for permit storage.
    struct Key: Hashable {
        let id: IO.Event.ID
        let interest: IO.Event.Interest
    }
}
