//
//  IO.Handoff.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 28/12/2025.
//

extension IO {
    /// Namespace for cross-boundary ownership transfer primitives.
    ///
    /// Handoff provides a single, auditable mechanism for transferring ownership
    /// of `~Copyable` values across escaping `@Sendable` boundaries (e.g., to OS threads,
    /// lane workers, or other async contexts).
    ///
    /// ## Design
    /// - `Cell<T>`: Heap storage for a single `~Copyable` value
    /// - `Token`: Sendable capability representing exclusive ownership
    /// - Exactly-once consumption enforced by `~Copyable` constraints
    ///
    /// ## Usage
    /// ```swift
    /// let cell = IO.Handoff.Cell(myValue)
    /// let token = cell.token()
    ///
    /// // token is Sendable, can cross thread boundaries
    /// IO.Thread.spawn {
    ///     let value = IO.Handoff.Cell<MyType>.take(token)
    ///     // use value
    /// }
    /// ```
    ///
    /// ## Invariants
    /// 1. `Cell` is single-owner (`~Copyable`) and yields exactly one `Token`
    /// 2. `Token` is a capability, not a pointer API - only valid operation is `take()`
    /// 3. `take()` must be called exactly once; if not, storage leaks
    /// 4. Calling `take()` twice with the same token is undefined behavior
    public enum Handoff {}
}

// MARK: - Token

extension IO.Handoff {
    /// Sendable capability token representing exclusive ownership of a pending value.
    ///
    /// This is an opaque ownership token, not a pointer to be manipulated.
    /// The only valid operation is to pass it to `Cell.take(_:)`.
    public struct Token: Sendable {
        @usableFromInline
        let bits: UInt

        @usableFromInline
        init(bits: UInt) {
            self.bits = bits
        }
    }
}

// MARK: - Cell

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

        /// Produces a Sendable token and consumes the cell.
        ///
        /// After calling this method, the cell cannot be used again.
        /// The token represents exclusive ownership of the stored value
        /// and must be passed to `take(_:)` exactly once.
        @inlinable
        public consuming func token() -> Token {
            Token(bits: UInt(bitPattern: storage))
        }

        /// Consumes the token, moves the value out, and deallocates storage.
        ///
        /// - Parameter token: The ownership token produced by `token()`.
        /// - Returns: The stored value.
        ///
        /// - Precondition: Must be called exactly once per token.
        ///   Calling twice with the same token is undefined behavior.
        @inlinable
        public static func take(_ token: consuming Token) -> T {
            let ptr = UnsafeMutablePointer<T>(bitPattern: Int(token.bits))!
            let value = ptr.move()
            ptr.deallocate()
            return value
        }
    }
}
