//
//  IO.Executor.Slot.Address.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 24/12/2025.
//

extension IO.Executor.Slot {
    /// A typed capability for a slot's memory address.
    ///
    /// ## Unsafe Boundary Contract
    ///
    /// This type enables Sendable transport of a slot's address across
    /// await boundaries without making the resource itself Sendable.
    ///
    /// **Provenance**: Created from a `Container.address` property.
    /// The underlying slot must have been allocated via `Container.allocate()`.
    ///
    /// **Lifetime Guarantee**: The caller must ensure the underlying slot
    /// remains allocated for the duration of any `pointer` access.
    /// Typically guaranteed by:
    /// 1. Slot lifetime scoped to an actor method
    /// 2. `lane.run` awaited within that scope
    /// 3. `deallocateRawOnly()` called only after lane returns
    ///
    /// **Thread Safety**: The address itself (a `UInt`) is Sendable.
    /// Access via `pointer` must only occur on the lane's execution context.
    ///
    /// **Null Check**: `pointer` traps if the address is zero. This indicates
    /// a bug (address created from nil Container.raw).
    ///
    /// Provides a Sendable handle to the slot's memory that can be
    /// safely captured in @Sendable closures and later used to reconstruct
    /// the raw pointer.
    //
    // Design:
    // - Wraps a UInt (which is Sendable) rather than UnsafeMutableRawPointer
    // - Provides typed access via `pointer` property
    // - Enforces single usage pattern through the type system
    struct Address: Sendable, Hashable {
        private let rawValue: UInt

        init(_ rawValue: UInt) {
            self.rawValue = rawValue
        }

        /// Reconstructs the raw pointer from the address.
        ///
        /// - Important: Only call this inside a lane closure where the slot
        ///   is guaranteed to be alive.
        var pointer: UnsafeMutableRawPointer {
            guard let ptr = UnsafeMutableRawPointer(bitPattern: rawValue) else {
                preconditionFailure("Invalid slot address (null pointer)")
            }
            return ptr
        }
    }
}
