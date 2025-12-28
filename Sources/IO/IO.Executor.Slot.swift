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
    /// ## Relationship to IO.Handoff
    /// Slot uses `IO.Handoff.Token` as its address capability type (via typealias).
    /// Both solve "cross Sendable boundary" problems using the same opaque token pattern.
    ///
    /// - **IO.Handoff.Cell**: Simple one-shot ownership transfer (init → token → take)
    /// - **IO.Executor.Slot.Container**: Two-phase lane execution pattern with
    ///   separate allocation, initialization, and consumption phases
    ///
    /// Slot has richer lifecycle semantics because lane workers may initialize
    /// the resource (not just receive it), and cleanup must handle partial failures.
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
}

extension IO.Executor.Slot {
    /// Opaque address capability for slot memory.
    ///
    /// This is a typealias to `IO.Handoff.Token`, providing a unified
    /// representation for address-sized capabilities across IO subsystems.
    public typealias Address = IO.Handoff.Token
}
