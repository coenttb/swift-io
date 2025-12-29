//
//  IO.Handoff.Storage.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 29/12/2025.
//

extension IO.Handoff {
    /// Storage for "create inside closure, retrieve after" pattern.
    ///
    /// Use Storage when a value will be created inside an escaping `@Sendable`
    /// closure and you need to retrieve it after the closure completes.
    ///
    /// ## Ownership Model
    /// - `init()` allocates empty ARC-managed storage
    /// - `token` produces a Sendable token for storing
    /// - `token.store(_:)` stores the value (exactly once, enforced atomically)
    /// - `take()` retrieves the stored value and consumes the storage
    ///
    /// ## Thread Safety
    /// Designed for single-producer/single-consumer with happens-before:
    /// - Producer calls `store()` inside lane/thread
    /// - `await` provides happens-before
    /// - Consumer calls `take()` after await
    ///
    /// Multiple copies of the token may exist (it's Copyable), but only one
    /// `store()` call will succeed. Additional calls trap deterministically.
    ///
    /// ## Usage
    /// ```swift
    /// let storage = IO.Handoff.Storage<MyType>()
    /// let storeToken = storage.token
    /// await lane.run {
    ///     storeToken.store(createValue())
    /// }
    /// let value = storage.take()
    /// ```
    public struct Storage<T: ~Copyable>: ~Copyable {
        @usableFromInline
        let _box: _Box<T>

        /// Creates empty storage.
        @inlinable
        public init() {
            _box = _Box()
        }
    }
}

// MARK: - Token

extension IO.Handoff.Storage where T: ~Copyable {
    /// Token for storing a value into Storage.
    ///
    /// ## Safety
    /// - `Sendable`: Can cross thread boundaries safely
    /// - `Copyable`: Can be captured in escaping closures (required for lane/thread use)
    /// - ARC-managed: Strong reference to box, no retain-count hazards
    /// - Atomic one-shot: `store()` enforced atomically, second call traps
    ///
    /// ## Thread Safety
    /// Multiple copies of a token may exist (it's Copyable), but only one
    /// `store()` call will succeed. Additional calls trap deterministically.
    ///
    /// ## Invariants
    /// - `store()` must be called exactly once across all copies
    /// - Calling `store()` twice (on any copy) traps with a clear error message
    public struct Token: Sendable {
        /// Strong reference to the box. ARC manages lifetime.
        @usableFromInline
        let _box: IO.Handoff._Box<T>

        @usableFromInline
        init(_ box: IO.Handoff._Box<T>) {
            self._box = box
        }

        /// Atomically stores a value.
        ///
        /// - Parameter value: The value to store.
        /// - Precondition: Must be called exactly once across all token copies.
        ///   Second call traps with a clear error message.
        @inlinable
        public func store(_ value: consuming T) {
            _box.store(value)
        }
    }
}

// MARK: - Storage Operations

extension IO.Handoff.Storage where T: ~Copyable {
    /// Returns a token for storing a value.
    ///
    /// The token must be consumed by calling `store(_:)` exactly once.
    /// This does NOT consume the storage - you still call `take()` afterward.
    @inlinable
    public var token: Token {
        Token(_box)
    }

    /// Retrieves the stored value and consumes the storage.
    ///
    /// - Returns: The stored value.
    /// - Precondition: `store()` must have been called exactly once.
    @inlinable
    public consuming func take() -> T {
        _box.take()
    }

    /// Retrieves the value if stored, otherwise returns nil.
    ///
    /// Use this for cleanup paths where storage may or may not have been filled.
    ///
    /// - Returns: The stored value if `store()` was called, nil otherwise.
    @inlinable
    public consuming func takeIfStored() -> T? {
        _box.takeIfPresent()
    }
}
