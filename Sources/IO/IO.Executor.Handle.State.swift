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
    /// - `destroyed`: Handle closed or marked for closure
    enum State {
        case present
        case checkedOut
        case destroyed
    }
}
