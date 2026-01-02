//
//  IO.Handle.Waiter.State.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 28/12/2025.
//

import Synchronization

extension IO.Handle.Waiter {
    // Internal state representation.
    //
    // Uses bit patterns for atomic operations:
    // - Bit 0: cancelled flag
    // - Bit 1: armed flag (continuation bound)
    // - Bit 2: drained flag (continuation taken)
    //
    // State machine:
    // ```
    // unarmed ─────arm()─────▶ armed ──cancel()──▶ armedCancelled
    //    │                       │                      │
    //    │cancel()               │                      │
    //    ▼                       ▼                      ▼
    // cancelledUnarmed       takeForResume()       takeForResume()
    //    │                       │                      │
    //    │arm()                  ▼                      ▼
    //    ▼                    drained            cancelledDrained
    // armedCancelled
    // ```
    struct State: RawRepresentable, AtomicRepresentable, Equatable {
        var rawValue: UInt8
    }
}

extension IO.Handle.Waiter.State {
    static let unarmed = Self(rawValue: 0b000)
    static let cancelledUnarmed = Self(rawValue: 0b001)
    static let armed = Self(rawValue: 0b010)
    static let armedCancelled = Self(rawValue: 0b011)
    static let drained = Self(rawValue: 0b110)
    static let cancelledDrained = Self(rawValue: 0b111)
}

extension IO.Handle.Waiter.State {
    var isCancelled: Bool { rawValue & 0b001 != 0 }
    var isArmed: Bool { rawValue & 0b010 != 0 }
    var isDrained: Bool { rawValue & 0b100 != 0 }
}
