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
    /// - `pendingRegistration`: ID reserved, waiting for resource from lane
    /// - `present`: Handle is stored and available
    /// - `checkedOut`: Handle temporarily moved for transaction
    /// - `reserved`: Handle assigned to a specific waiter (by token)
    /// - `destroyed`: Handle closed or marked for closure
    ///
    /// ## Two-Phase Registration Flow
    ///
    /// When using `register { make }` convenience:
    /// 1. Reserve ID → entry created with `pendingRegistration` state
    /// 2. Lane work creates resource
    /// 3. Commit → state becomes `present` with resource stored
    /// 4. If commit fails (shutdown), entry removed and resource teardown runs
    ///
    /// ## Waiter Reservation Flow
    ///
    /// When a task checks in a handle and waiters exist:
    /// 1. Handle moves to `reserved(waiterToken:)` state
    /// 2. The waiter with matching token is resumed
    /// 3. Waiter claims handle by token → state becomes `checkedOut`
    ///
    /// This ensures the woken waiter always gets the handle without re-validation.
    internal enum State: Sendable, Equatable {
        case pendingRegistration
        case present
        case checkedOut
        case reserved(waiterToken: UInt64)
        case destroyed
    }
}
