//
//  IO.Executor.Slot.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 24/12/2025.
//

extension IO.Executor {
    /// Namespace for slot-related types used in lane execution.
    ///
    /// Slots provide internal bridging for ~Copyable resources across await
    /// boundaries via lane.run.
    ///
    /// ## Safety Invariants
    /// 1. The slot is initialized exactly once (via static `initializeMemory`)
    /// 2. After successful lane.run, caller marks initialized and calls `take()`
    /// 3. `deallocateRawOnly()` is idempotent and called via defer
    ///
    /// ## Usage Pattern
    /// ```swift
    /// var slot = IO.Executor.Slot.Container<MyResource>.allocate()
    /// defer { slot.deallocateRawOnly() }
    /// let address = slot.address  // Opaque token capability
    ///
    /// try await lane.run(deadline: nil) {
    ///     // Use static methods with the address token
    ///     let resource = try openResource(...)
    ///     IO.Executor.Slot.Container<MyResource>.initializeMemory(at: address, with: resource)
    /// }
    ///
    /// slot.markInitialized()
    /// let resource = slot.take()
    /// // register resource
    /// ```
    public enum Slot {}

    // ## Relationship to IO.Handoff
    // Both Slot and IO.Handoff solve "cross Sendable boundary" problems:
    //
    // - **IO.Handoff.Cell**: Simple one-shot ownership transfer (init → token → take)
    // - **IO.Handoff.Storage**: Create inside closure, retrieve after (init → token → store → take)
    // - **IO.Executor.Slot.Container**: Two-phase lane execution pattern with
    //   separate allocation, initialization, and consumption phases
    //
    // Slot has richer lifecycle semantics because lane workers may initialize
    // the resource (not just receive it), and cleanup must handle partial failures.
    //
}

extension IO.Executor.Slot {
    /// Opaque address capability for slot memory.
    ///
    /// Encodes a raw pointer as a Sendable capability that can cross
    /// escaping closure boundaries.
    public struct Address: Sendable {
        @usableFromInline
        let bits: UInt

        @usableFromInline
        init(bits: UInt) {
            self.bits = bits
        }

        /// Package-internal pointer reconstruction.
        ///
        /// The caller must guarantee the memory is still allocated.
        @usableFromInline
        var _pointer: UnsafeMutableRawPointer {
            precondition(bits != 0, "Address used after deallocation or with null pointer")
            return UnsafeMutableRawPointer(bitPattern: Int(bits))!
        }
    }
}
