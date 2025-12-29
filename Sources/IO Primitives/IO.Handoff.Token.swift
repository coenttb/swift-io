//
//  IO.Handoff.Token.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 28/12/2025.
//

extension IO.Handoff {
    /// Sendable capability token representing an address-sized value.
    ///
    /// ## Semantic Contract
    /// - Token is an opaque capability that encodes an address-sized bit pattern
    /// - Valid only within the process and lifetime defined by the producing subsystem
    /// - Not intended for persistence or round-tripping
    /// - The only public operation is passing it to the subsystem that created it
    ///
    /// ## Usage
    /// Tokens are created by subsystems (`Cell.token()`, `Slot.Container.address`)
    /// and consumed by those same subsystems. Do not attempt to forge or inspect.
    public struct Token: Sendable {
        @usableFromInline
        package let bits: UInt

        @usableFromInline
        package init(bits: UInt) {
            self.bits = bits
        }
    }
}

extension IO.Handoff.Token {
    /// Package-internal pointer reconstruction.
    ///
    /// Only subsystems that own the lifetime invariant should use this.
    /// The caller must guarantee the memory is still allocated.
    @usableFromInline
    package var _pointer: UnsafeMutableRawPointer {
        precondition(bits != 0, "Token used after deallocation or with null address")
        return UnsafeMutableRawPointer(bitPattern: Int(bits))!
    }
}
