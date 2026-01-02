//
//  IO.Completion.Driver.Handle.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 31/12/2025.
//

extension IO.Completion.Driver {
    /// Opaque, platform-specific completion handle.
    ///
    /// The handle is `~Copyable` to enforce single ownership and ensure
    /// proper cleanup. It is owned by the poll thread for its entire lifetime.
    ///
    /// ## Platform Storage
    ///
    /// - **Windows**: `CreateIoCompletionPort()` handle (`HANDLE`)
    /// - **Linux**: io_uring ring file descriptor + ring memory pointer
    /// - **Darwin**: kqueue fd (for Fake driver testing only)
    ///
    /// ## Thread Safety
    ///
    /// The handle itself is not thread-safe. All operations on the handle
    /// must be serialized on the poll thread. The only exception is wakeup,
    /// which uses a separate `Wakeup.Channel` that is thread-safe.
    ///
    /// ## Opacity
    ///
    /// The handle is opaque to users. Platform backends access the underlying
    /// value via conditional package accessors.
    public struct Handle: ~Copyable, @unchecked Sendable {
        // MARK: - Platform-Conditional Storage

        #if os(Windows)
            /// Windows IOCP handle storage.
            @usableFromInline
            package let _raw: UnsafeMutableRawPointer
        #elseif os(Linux)
            /// Linux io_uring or epoll descriptor.
            @usableFromInline
            package let _descriptor: Int32

            /// io_uring ring memory pointer (nil for epoll fallback).
            @usableFromInline
            package let _ringPtr: UnsafeMutableRawPointer?
        #else
            /// Darwin kqueue descriptor.
            @usableFromInline
            package let _descriptor: Int32
        #endif

        // MARK: - Platform-Conditional Initializers

        #if os(Windows)
            /// Creates a handle from a Windows IOCP HANDLE.
            ///
            /// - Parameter raw: The raw IOCP handle pointer.
            @usableFromInline
            package init(raw: UnsafeMutableRawPointer) {
                self._raw = raw
            }
        #elseif os(Linux)
            /// Creates a handle from a Linux io_uring or epoll fd.
            ///
            /// - Parameters:
            ///   - descriptor: The file descriptor (io_uring fd or epoll fd).
            ///   - ringPtr: The io_uring ring memory pointer (nil for epoll).
            @usableFromInline
            package init(descriptor: Int32, ringPtr: UnsafeMutableRawPointer? = nil) {
                self._descriptor = descriptor
                self._ringPtr = ringPtr
            }
        #else
            /// Creates a handle from a Darwin kqueue fd.
            ///
            /// - Parameter descriptor: The kqueue file descriptor.
            @usableFromInline
            package init(descriptor: Int32) {
                self._descriptor = descriptor
            }
        #endif

        // MARK: - Platform-Conditional Accessors

        #if os(Windows)
            /// The raw Windows IOCP handle pointer.
            ///
            /// For use by IOCP backend only.
            @usableFromInline
            package var raw: UnsafeMutableRawPointer { _raw }
        #elseif os(Linux)
            /// The Linux file descriptor (io_uring or epoll).
            ///
            /// For use by io_uring/epoll backends only.
            @usableFromInline
            package var descriptor: Int32 { _descriptor }

            /// The io_uring ring memory pointer.
            ///
            /// Returns `nil` for epoll fallback mode.
            @usableFromInline
            package var ringPtr: UnsafeMutableRawPointer? { _ringPtr }

            /// Whether this handle uses io_uring (vs epoll fallback).
            @usableFromInline
            package var isIOUring: Bool { _ringPtr != nil }
        #else
            /// The Darwin file descriptor.
            ///
            /// For use by Fake driver testing only (Darwin has no completion backend).
            @usableFromInline
            package var descriptor: Int32 { _descriptor }
        #endif
    }
}
