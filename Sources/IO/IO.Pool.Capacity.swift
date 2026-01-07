//
//  IO.Pool.Capacity.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 07/01/2026.
//

extension IO.Pool where Resource: ~Copyable {
    /// Pool capacity configuration.
    ///
    /// ## Usage
    ///
    /// ```swift
    /// let pool = IO.Pool(on: lane, capacity: 16) { ... }
    /// // or
    /// let pool = IO.Pool(on: lane, capacity: .init(16)) { ... }
    /// ```
    public struct Capacity: Sendable, Hashable {
        /// The maximum number of resources.
        public let value: Int

        /// Creates a capacity with the given value.
        ///
        /// - Parameter value: Maximum number of resources. Must be > 0.
        @inlinable
        public init(_ value: Int) {
            precondition(value > 0, "Pool capacity must be > 0")
            self.value = value
        }
    }
}

// MARK: - ExpressibleByIntegerLiteral

extension IO.Pool.Capacity: ExpressibleByIntegerLiteral {
    @inlinable
    public init(integerLiteral value: Int) {
        self.init(value)
    }
}

// MARK: - CustomStringConvertible

extension IO.Pool.Capacity: CustomStringConvertible {
    public var description: String {
        "\(value)"
    }
}
