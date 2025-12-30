//
//  Optional+take.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 30/12/2025.
//

/// Package-scoped extension for consuming ~Copyable optional values.
///
/// This is a stopgap utility until Swift stdlib provides equivalent functionality.
/// The underscore prefix signals this is internal infrastructure that may be
/// removed when stdlib alternatives become available.
extension Optional where Wrapped: ~Copyable {
    /// Takes the value out of the optional, leaving nil behind.
    ///
    /// This is the canonical pattern for consuming ~Copyable optional stored properties.
    /// Uses `consume self` to move the value out, then reassigns nil to the storage.
    ///
    /// ## Usage
    /// ```swift
    /// var handle: IO.Thread.Handle? = ...
    /// guard let h = handle._take() else { return }
    /// // handle is now nil, h owns the value
    /// ```
    ///
    /// - Returns: The wrapped value if present, nil otherwise.
    @usableFromInline
    package mutating func _take() -> Wrapped? {
        switch consume self {
        case .some(let value):
            self = nil
            return value
        case .none:
            self = nil
            return nil
        }
    }
}
