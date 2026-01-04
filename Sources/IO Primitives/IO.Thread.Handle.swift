//
//  IO.Thread.Handle.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 28/12/2025.
//

public import Kernel

extension IO.Thread {
    /// Opaque handle to an OS thread.
    ///
    /// This is a wrapper around `Kernel.Thread.Handle` that provides
    /// additional safety checks (like deadlock detection on join).
    ///
    /// ## Move-Only Semantics
    /// This type is `~Copyable` to enforce exactly-once `join()` semantics.
    /// Copying the handle would allow double-join, which is undefined behavior
    /// on all platforms.
    ///
    /// ## Safety
    /// This type is `@unchecked Sendable` because the underlying handle
    /// can be safely passed between threads.
    /// The move-only constraint ensures exactly-once consumption.
    public struct Handle: ~Copyable, @unchecked Sendable {
        @usableFromInline
        var kernelHandle: Kernel.Thread.Handle

        /// Creates an IO.Thread.Handle from a Kernel.Thread.Handle.
        @inlinable
        public init(_ kernelHandle: consuming Kernel.Thread.Handle) {
            self.kernelHandle = kernelHandle
        }
    }
}

extension IO.Thread.Handle {
    /// Wait for the thread to complete and release the handle.
    ///
    /// This is a consuming operation - the handle cannot be used after calling `join()`.
    ///
    /// - Precondition: Must NOT be called from this thread (deadlock).
    /// - Note: Must be called exactly once. The `~Copyable` constraint enforces this.
    @inlinable
    public consuming func join() {
        precondition(
            isCurrent == false,
            "IO.Thread.Handle.join() called on the current thread"
        )
        kernelHandle.join()
    }

    /// Check if the current thread is this thread.
    ///
    /// Used for shutdown safety to prevent join-on-self deadlock.
    @inlinable
    public var isCurrent: Bool {
        kernelHandle.isCurrent
    }
}
