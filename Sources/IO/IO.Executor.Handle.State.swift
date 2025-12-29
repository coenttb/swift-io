//
//  IO.Executor.Handle.State.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 24/12/2025.
//

extension IO.Executor.Handle {
    /// Lifecycle state of a handle entry.
    ///
    /// Distinguishes between:
    /// - `present`: Handle is stored and available
    /// - `checkedOut`: Handle temporarily moved for transaction
    /// - `reserved`: Handle assigned to a specific waiter (by token)
    /// - `destroyed`: Handle closed or marked for closure
    ///
    /// ## Reservation Flow
    ///
    /// When a task checks in a handle and waiters exist:
    /// 1. Handle moves to `reserved(waiterToken:)` state
    /// 2. The waiter with matching token is resumed
    /// 3. Waiter claims handle by token → state becomes `checkedOut`
    ///
    /// This ensures the woken waiter always gets the handle without re-validation.
    public enum State: Sendable, Equatable {
        case present
        case checkedOut
        case reserved(waiterToken: UInt64)
        case destroyed
    }
}
