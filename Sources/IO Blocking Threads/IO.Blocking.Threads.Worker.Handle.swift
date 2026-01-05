//
//  IO.Blocking.Threads.Worker.Handle.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 30/12/2025.
//

import IO_Primitives

extension IO.Blocking.Threads.Worker {
    /// Reference wrapper for a ~Copyable thread handle.
    ///
    /// This class allows storing `Kernel.Thread.Handle` (which is ~Copyable) in
    /// arrays and other Copyable containers. The reference type is Copyable,
    /// but the inner handle enforces exactly-once join semantics.
    ///
    /// ## Safety Invariant
    /// - `join()` consumes the inner handle exactly once
    /// - Calling `join()` twice traps with a diagnostic message
    /// - The `deinit` verifies the handle was joined (no leaked threads)
    ///
    /// ## Thread Safety
    /// This type is `@unchecked Sendable` because:
    /// - The handle is only accessed from Runtime's controlled lifecycle
    /// - `join()` is called exactly once during `joinAllThreads()`
    final class Handle: @unchecked Sendable {
        private var inner: Kernel.Thread.Handle?

        /// Creates a wrapper owning the given thread handle.
        init(_ handle: consuming Kernel.Thread.Handle) {
            self.inner = consume handle
        }

        /// Joins the thread, consuming the handle.
        ///
        /// - Precondition: Must be called exactly once.
        func join() {
            guard let handle = inner._take() else {
                preconditionFailure(
                    "IO.Blocking.Threads.Worker.Handle.join() called twice"
                )
            }
            handle.join()
        }

        deinit {
            // Verify handle was joined - if not, we're leaking a thread
            precondition(
                inner == nil,
                "IO.Blocking.Threads.Worker.Handle deallocated without join()"
            )
        }
    }
}
