//
//  IO.RetainedPointer.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 28/12/2025.
//

extension IO {
    /// A move-only Sendable wrapper for transferring retained object ownership
    /// across thread boundaries.
    ///
    /// This type encapsulates the unsafe pointer representation needed to pass a retained
    /// reference across a Sendable boundary (e.g., to an OS thread). The wrapped object
    /// is retained on creation and released when `take()` is called.
    ///
    /// ## Usage
    /// ```swift
    /// let retained = IO.RetainedPointer(self)
    /// IO.Thread.spawn { [retained] in
    ///     let executor = retained.take()
    ///     executor.runLoop()
    /// }
    /// ```
    ///
    /// ## Ownership Model
    /// - `init(_:)` retains the object (+1 retain count)
    /// - Ownership is transferred to exactly one consumer
    /// - `take()` must be called exactly once and consumes `self`
    /// - After `take()`, the caller owns the object and is responsible for its lifetime
    ///
    /// ## Thread Safety
    /// `@unchecked Sendable` because it is an opaque, single-consumption ownership
    /// token. The produced `T` may or may not be safe to use concurrently; that is
    /// a property of `T` and the surrounding program. It is `~Copyable` to enforce
    /// single-consumption at compile time.
    ///
    /// ## Invariant
    /// `take()` must be called exactly once. The `~Copyable` constraint makes
    /// double-take unrepresentable.
    struct RetainedPointer<T: AnyObject>: ~Copyable, @unchecked Sendable {
        /// Opaque bit representation of the retained pointer.
        /// This is NOT a pointer to be manipulated - it is an ownership token
        /// that must be round-tripped back via `take()`.
        private let raw: UnsafeMutableRawPointer

        /// Creates a retained pointer wrapper, incrementing the object's retain count.
        ///
        /// - Parameter instance: The object to retain.
        init(_ instance: T) {
            self.raw = Unmanaged.passRetained(instance).toOpaque()
        }

        /// Takes ownership of the retained object, decrementing the retain count.
        ///
        /// This method consumes `self`, ensuring it can only be called once.
        ///
        /// - Returns: The retained object. The caller now owns this reference.
        consuming func take() -> T {
            Unmanaged<T>.fromOpaque(raw).takeRetainedValue()
        }
    }
}
