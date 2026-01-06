//
//  IO.Event.Waiter.State.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 29/12/2025.
//

import Synchronization

extension IO.Event.Waiter {
    /// Internal state representation.
    ///
    /// Uses bit patterns for atomic operations:
    /// - Bit 0: cancelled flag
    /// - Bit 1: armed flag (continuation bound)
    /// - Bit 2: drained flag (continuation taken)
    struct State: RawRepresentable, AtomicRepresentable, Equatable {
        var rawValue: UInt8

        static let unarmed = State(rawValue: 0b000)
        static let cancelledUnarmed = State(rawValue: 0b001)
        static let armed = State(rawValue: 0b010)
        static let armedCancelled = State(rawValue: 0b011)
        static let drained = State(rawValue: 0b110)
        static let cancelledDrained = State(rawValue: 0b111)

        var isCancelled: Bool { rawValue & 0b001 != 0 }
        var isArmed: Bool { rawValue & 0b010 != 0 }
        var isDrained: Bool { rawValue & 0b100 != 0 }

        init(rawValue: UInt8) {
            self.rawValue = rawValue
        }
    }
}
