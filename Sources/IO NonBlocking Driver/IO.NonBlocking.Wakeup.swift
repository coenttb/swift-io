//
//  IO.NonBlocking.Wakeup.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 28/12/2025.
//

extension IO.NonBlocking {
    /// Namespace for wakeup-related types.
    public enum Wakeup {
        /// Thread-safe channel for waking the poll thread.
        ///
        /// The `Wakeup.Channel` provides a way for the selector actor to wake
        /// the poll thread without needing access to the driver handle. This
        /// is essential because:
        /// - The handle is owned by the poll thread
        /// - The selector needs to signal shutdown, new registrations, etc.
        /// - The wakeup mechanism must be thread-safe
        ///
        /// ## Platform Implementation
        /// - **kqueue**: Uses `EVFILT_USER` event
        /// - **epoll**: Uses `eventfd` write
        /// - **IOCP**: Uses `PostQueuedCompletionStatus` with sentinel
        ///
        /// ## Usage
        /// ```swift
        /// // Created during Selector.make()
        /// let wakeupChannel = try driver.createWakeupChannel(handle)
        ///
        /// // Selector holds the channel
        /// // Can be called from any thread:
        /// wakeupChannel.wake()
        /// ```
        ///
        /// ## Thread Safety
        /// The `wake()` method is thread-safe and can be called from any context.
        /// Multiple concurrent calls are coalesced (only one wakeup is delivered).
        public struct Channel: Sendable {
            /// The thread-safe wakeup closure.
            private let signal: @Sendable () -> Void

            /// Creates a wakeup channel with the given signal closure.
            ///
            /// - Parameter signal: A thread-safe closure that wakes the poll thread.
            public init(signal: @escaping @Sendable () -> Void) {
                self.signal = signal
            }

            /// Wake the poll thread.
            ///
            /// This method is thread-safe and can be called from any context,
            /// including from the selector actor, cancellation handlers, or
            /// other threads.
            ///
            /// If the poll thread is currently blocked in `poll()`, it will
            /// return with a wakeup event (or empty result, depending on
            /// implementation). If the poll thread is not blocked, the wakeup
            /// may be coalesced with the next poll.
            public func wake() {
                signal()
            }
        }
    }
}
