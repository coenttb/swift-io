//
//  IO.NonBlocking.Driver.Handle.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 28/12/2025.
//

extension IO.NonBlocking.Driver {
    /// Opaque, platform-specific selector handle.
    ///
    /// The handle is `~Copyable` to enforce single ownership and ensure
    /// proper cleanup. It is owned by the poll thread for its entire lifetime.
    ///
    /// ## Platform Storage
    /// - **Darwin**: `kqueue()` file descriptor (`Int32`)
    /// - **Linux**: `epoll_create1()` file descriptor (`Int32`)
    /// - **Windows**: `CreateIoCompletionPort()` handle (`HANDLE`)
    ///
    /// ## Thread Safety
    /// The handle itself is not thread-safe. All operations on the handle
    /// must be serialized on the poll thread. The only exception is wakeup,
    /// which uses a separate `WakeupChannel` that is thread-safe.
    public struct Handle: ~Copyable, Sendable {
        /// Platform-specific storage.
        ///
        /// On Unix systems, this is the file descriptor.
        /// On Windows, this would be a handle value.
        @usableFromInline
        package let rawValue: Int32

        /// Creates a handle from a raw file descriptor.
        @usableFromInline
        package init(rawValue: Int32) {
            self.rawValue = rawValue
        }
    }
}
