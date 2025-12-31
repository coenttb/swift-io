//
//  IO.Event.Driver.Handle.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 28/12/2025.
//

extension IO.Event.Driver {
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
    ///
    /// ## Opacity
    /// The handle is opaque to users. Platform backends access the underlying
    /// value via conditional internal accessors.
    public struct Handle: ~Copyable, Sendable {
        // MARK: - Platform-Conditional Storage

        #if os(Windows)
        /// Windows IOCP handle storage.
        @usableFromInline
        package let _raw: UnsafeMutableRawPointer
        #else
        /// Unix file descriptor storage (Darwin kqueue, Linux epoll).
        @usableFromInline
        package let _descriptor: Int32
        #endif

        // MARK: - Platform-Conditional Initializers

        #if os(Windows)
        /// Creates a handle from a Windows HANDLE.
        ///
        /// - Parameter raw: The raw IOCP handle pointer.
        @usableFromInline
        package init(raw: UnsafeMutableRawPointer) {
            self._raw = raw
        }
        #else
        /// Creates a handle from a Unix file descriptor.
        ///
        /// - Parameter rawValue: The file descriptor (kqueue fd, epoll fd).
        @usableFromInline
        package init(rawValue: Int32) {
            self._descriptor = rawValue
        }
        #endif

        // MARK: - Platform-Conditional Accessors

        #if os(Windows)
        /// The raw Windows handle pointer.
        ///
        /// For use by IOCP backend only.
        @usableFromInline
        package var raw: UnsafeMutableRawPointer { _raw }
        #else
        /// The Unix file descriptor.
        ///
        /// For use by kqueue/epoll backends only.
        @usableFromInline
        package var rawValue: Int32 { _descriptor }
        #endif
    }
}
