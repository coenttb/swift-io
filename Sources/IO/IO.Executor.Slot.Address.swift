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
        private let rawValue: UInt

        init(_ rawValue: UInt) {
            self.rawValue = rawValue
        }

        /// Reconstructs the raw pointer from the address.
        ///
        /// - Important: Only call this inside a lane closure where the slot
        ///   is guaranteed to be alive.
        public var pointer: UnsafeMutableRawPointer {
            guard let ptr = UnsafeMutableRawPointer(bitPattern: rawValue) else {
                preconditionFailure("Invalid slot address (null pointer)")
            }
            return ptr
        }
    }
}
