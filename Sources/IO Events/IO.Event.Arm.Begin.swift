//
//  IO.Event.Arm.Begin.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 28/12/2025.
//

extension IO.Event.Arm {
    /// Result of beginning an arm operation.
    ///
    /// Phase 1 (`beginArmDiscardingToken`) returns either:
    /// - `.ready(IO.Event)`: A permit existed, readiness is immediate
    /// - `.pending(Handle)`: No permit, use handle with `awaitArm`
    ///
    /// ## Single-Consumer Semantics
    ///
    /// **Permits are consumed exactly once in phase 1.** The `.ready` case
    /// means the permit was consumed; `awaitArm` does NOT check permits.
    /// This ensures clean phase separation and prevents double-consumption.
    ///
    /// If an event arrives between phase 1 (`.pending`) and phase 2 (`awaitArm`),
    /// `processEvent` converts the readiness to a permit and removes the unarmed
    /// waiter. The subsequent `awaitArm` fails with `.cancelled` due to the
    /// missing waiter - the permit is available for a future `beginArmDiscardingToken`.
    @frozen
    public enum Begin: Sendable {
        /// Readiness was already available (permit consumed).
        /// No need to call `awaitArm`.
        case ready(IO.Event)

        /// No readiness yet. Use the handle with `awaitArm` to suspend.
        case pending(Handle)
    }
}
