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
    /// ## Key Design: Integer Address Capture
    /// UnsafeMutableRawPointer is not Sendable in Swift 6, but UInt is.
    /// We expose `slot.address` as a typed `Address` and reconstruct the pointer
    /// inside the @Sendable lane closure. Memory lifetime is guaranteed by the
    /// actor-scoped slot plus the awaited lane.run duration.
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
    /// let address = slot.address  // Typed Address capability
    ///
    /// try await lane.run(deadline: nil) {
    ///     let raw = address.pointer  // Reconstruct pointer from Address
    ///     let resource = try openResource(...)
    ///     IO.Executor.Slot.Container<MyResource>.initializeMemory(at: raw, with: resource)
    /// }
    ///
    /// slot.markInitialized()
    /// let resource = slot.take()
    /// // register resource
    /// ```
    public enum Slot {}
}
