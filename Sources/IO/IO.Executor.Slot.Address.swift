//
//  IO.Executor.Slot.Address.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 24/12/2025.
//

extension IO.Executor.Slot {
    /// A typed capability for a slot's memory address.
    ///
    /// This provides a Sendable handle to the slot's memory that can be
    /// safely captured in @Sendable closures and later used to reconstruct
    /// the raw pointer.
    ///
    /// ## Relationship to IO.Handoff.Token
    /// Address uses the same "UInt bits for Sendable crossing" pattern as
    /// `IO.Handoff.Token`. However, Address is used for the two-phase lane
    /// execution pattern (allocate → lane initializes → take), while Token
    /// is used for simple one-shot ownership transfer.
    ///
    /// ## Design
    /// - Wraps a UInt (which is Sendable) rather than UnsafeMutableRawPointer
    /// - Provides typed access via `pointer` property
    /// - Enforces single usage pattern through the type system
    ///
    /// ## Safety
    /// The caller must ensure the underlying slot remains allocated for the
    /// duration of any pointer access. Typically this is guaranteed by:
    /// 1. Slot lifetime scoped to an actor method
    /// 2. Lane.run awaited within that scope
    public struct Address: Sendable, Hashable {
        /// The underlying capability token.
        ///
        /// Stored as UInt for Sendable conformance - same pattern as IO.Handoff.Token.
        private let bits: UInt

        init(_ bits: UInt) {
            self.bits = bits
        }

        /// Reconstructs the raw pointer from the address.
        ///
        /// - Important: Only call this inside a lane closure where the slot
        ///   is guaranteed to be alive.
        public var pointer: UnsafeMutableRawPointer {
            guard let ptr = UnsafeMutableRawPointer(bitPattern: Int(bits)) else {
                preconditionFailure("Invalid slot address (null pointer)")
            }
            return ptr
        }
    }
}
