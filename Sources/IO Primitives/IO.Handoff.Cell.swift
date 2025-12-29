//
//  IO.Handoff.Cell.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 28/12/2025.
//

extension IO.Handoff {
    /// Heap cell that stores a single `~Copyable` value for cross-boundary transfer.
    ///
    /// ## Ownership Model
    /// - `init(_:)` allocates storage and moves the value in
    /// - `token()` produces a Sendable capability and consumes the cell
    /// - `take(_:)` consumes the token, moves the value out, and deallocates storage
    ///
    /// ## Thread Safety
    /// The cell itself is not thread-safe, but the `Token` it produces is `Sendable`
    /// and can safely cross thread boundaries. The receiving thread calls `take()`
    /// to recover the value.
    public struct Cell<T: ~Copyable>: ~Copyable {
        @usableFromInline
        let storage: UnsafeMutablePointer<T>

        /// Creates a cell containing the given value.
        ///
        /// The value is moved into heap storage. The cell must be consumed
        /// by calling `token()` to transfer ownership.
        @inlinable
        public init(_ value: consuming T) {
            storage = .allocate(capacity: 1)
            storage.initialize(to: value)
        }
    }
}

extension IO.Handoff.Cell where T: ~Copyable {
    /// Produces a Sendable token and consumes the cell.
    ///
    /// After calling this method, the cell cannot be used again.
    /// The token represents exclusive ownership of the stored value
    /// and must be passed to `take(_:)` exactly once.
    @inlinable
    public consuming func token() -> IO.Handoff.Token {
        IO.Handoff.Token(bits: UInt(bitPattern: storage))
    }

    /// Consumes the token, moves the value out, and deallocates storage.
    ///
    /// - Parameter token: The ownership token produced by `token()`.
    /// - Returns: The stored value.
    ///
    /// - Precondition: Must be called exactly once per token.
    ///   Calling twice with the same token is undefined behavior.
    @inlinable
    public static func take(_ token: consuming IO.Handoff.Token) -> T {
        let ptr = UnsafeMutablePointer<T>(bitPattern: Int(token.bits))!
        let value = ptr.move()
        ptr.deallocate()
        return value
    }
}
