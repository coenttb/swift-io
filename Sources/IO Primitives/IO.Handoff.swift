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
