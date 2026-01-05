//
//  IO.Blocking.Threads.Worker.Handle.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 30/12/2025.
//

extension IO.Blocking.Threads.Worker {
    /// Reference wrapper for a ~Copyable thread handle.
    ///
    /// Uses `Kernel.Thread.Handle.Reference` which allows storing
    /// `Kernel.Thread.Handle` (which is ~Copyable) in arrays and other
    /// Copyable containers. The reference type is Copyable, but the
    /// inner handle enforces exactly-once join semantics.
    ///
    /// ## Safety Invariant
    /// - `join()` consumes the inner handle exactly once
    /// - Calling `join()` twice traps with a diagnostic message
    /// - The `deinit` verifies the handle was joined (no leaked threads)
    typealias Handle = Kernel.Thread.Handle.Reference
}
