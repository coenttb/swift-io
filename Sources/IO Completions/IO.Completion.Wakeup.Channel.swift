//
//  IO.Completion.Wakeup.Channel.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 31/12/2025.
//

extension IO.Completion.Wakeup {
    /// A thread-safe channel for waking the poll thread.
    ///
    /// The wakeup channel allows any thread to signal the poll thread
    /// to stop waiting and process new work. This is essential for:
    /// - Submitting new operations from the queue actor
    /// - Initiating graceful shutdown
    /// - Handling task cancellation
    ///
    /// ## Platform Implementation
    ///
    /// - **IOCP**: `PostQueuedCompletionStatus` with sentinel key
    /// - **io_uring**: `eventfd` or `IORING_OP_NOP` with IOSQE_IO_DRAIN
    /// - **kqueue**: `EVFILT_USER` with `NOTE_TRIGGER`
    /// - **epoll**: `eventfd` with `write(1)`
    ///
    /// ## Thread Safety
    ///
    /// `Channel` is `Sendable` and can be called from any thread.
    /// Multiple concurrent wakeup calls are safe (idempotent).
    public struct Channel: Sendable {
        /// The wakeup implementation.
        @usableFromInline
        let _wake: @Sendable () -> Void

        /// Optional cleanup on close.
        @usableFromInline
        let _close: (@Sendable () -> Void)?

        /// Creates a wakeup channel.
        ///
        /// - Parameters:
        ///   - wake: The function to call to wake the poll thread.
        ///   - close: Optional cleanup function called when the channel is closed.
        public init(
            wake: @escaping @Sendable () -> Void,
            close: (@Sendable () -> Void)? = nil
        ) {
            self._wake = wake
            self._close = close
        }

        /// Wakes the poll thread.
        ///
        /// This method is idempotent and thread-safe. Multiple calls
        /// will result in at least one wakeup, but the poll thread
        /// will only wake once per poll cycle.
        @inlinable
        public func wake() {
            _wake()
        }

        /// Closes the wakeup channel and releases resources.
        ///
        /// After calling close, further wake calls have undefined behavior.
        @inlinable
        public func close() {
            _close?()
        }
    }
}
