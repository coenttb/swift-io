//
//  IO.Completion.Driver.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 31/12/2025.
//

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif os(Windows)
import WinSDK
#endif

@_exported public import IO_Completions_Primitives

extension IO.Completion {
    /// Protocol witness struct for platform-specific completion backends.
    ///
    /// The Driver provides a uniform interface over platform-specific
    /// completion mechanisms:
    /// - **Windows**: IOCP (I/O Completion Ports)
    /// - **Linux**: io_uring (with epoll fallback)
    /// - **Darwin**: EventsAdapter (completion façade over kqueue)
    ///
    /// ## Thread Safety Model
    ///
    /// All driver operations are invoked **only on the poll thread**.
    /// The queue actor never touches the driver handle directly.
    /// Communication between queue and poll thread uses thread-safe
    /// primitives: `Bridge`, `Wakeup.Channel`, `Submission.Queue`.
    ///
    /// ## Ownership
    ///
    /// - `Handle` is `~Copyable` and owned by the poll thread
    /// - `_close` consumes the handle; all other operations borrow it
    /// - `Wakeup.Channel` is created separately and is `Sendable`
    ///
    /// ## Usage
    ///
    /// ```swift
    /// let driver = try IO.Completion.Driver.bestAvailable()
    /// let handle = try driver.create()
    /// let wakeupChannel = try driver.createWakeupChannel(handle)
    /// // Transfer handle to poll thread, keep wakeupChannel for queue
    /// ```
    public struct Driver: Sendable {
        /// Capabilities of this driver backend.
        public let capabilities: Capabilities

        // MARK: - Witness Closures

        /// Create a new completion handle.
        let _create: @Sendable () throws(Error) -> Handle

        /// Submit an operation for completion.
        ///
        /// Called from poll thread only.
        let _submit: @Sendable (
            borrowing Handle,
            borrowing Operation
        ) throws(Error) -> Void

        /// Flush pending submissions to the kernel.
        ///
        /// Called from poll thread only. Returns number of submissions flushed.
        /// For IOCP: no-op (immediate submission).
        /// For io_uring: io_uring_enter if SQ has pending entries.
        let _flush: @Sendable (borrowing Handle) throws(Error) -> Int

        /// Wait for completion events.
        ///
        /// Called from poll thread only. This is the blocking call.
        ///
        /// - Parameters:
        ///   - handle: The completion handle.
        ///   - deadline: Optional absolute deadline, or `nil` for infinite wait.
        ///   - buffer: Pre-allocated event buffer.
        /// - Returns: Number of events written to buffer.
        let _poll: @Sendable (
            borrowing Handle,
            Deadline?,
            inout [Event]
        ) throws(Error) -> Int

        /// Close the completion handle.
        ///
        /// Called from poll thread only. Consumes the handle.
        let _close: @Sendable (consuming Handle) -> Void

        /// Create a wakeup channel for this handle.
        ///
        /// The returned channel is `Sendable` and can be used from any thread
        /// to wake the poll thread. Uses platform-specific primitives:
        /// - IOCP: `PostQueuedCompletionStatus`
        /// - io_uring: eventfd or IORING_OP_NOP
        /// - EventsAdapter: kqueue EVFILT_USER or eventfd
        let _createWakeupChannel: @Sendable (borrowing Handle) throws(Error) -> Wakeup.Channel

        // MARK: - Initialization

        /// Creates a driver with the given witness closures.
        public init(
            capabilities: Capabilities,
            create: @escaping @Sendable () throws(Error) -> Handle,
            submit: @escaping @Sendable (borrowing Handle, borrowing Operation) throws(Error) -> Void,
            flush: @escaping @Sendable (borrowing Handle) throws(Error) -> Int,
            poll: @escaping @Sendable (borrowing Handle, Deadline?, inout [Event]) throws(Error) -> Int,
            close: @escaping @Sendable (consuming Handle) -> Void,
            createWakeupChannel: @escaping @Sendable (borrowing Handle) throws(Error) -> Wakeup.Channel
        ) {
            self.capabilities = capabilities
            self._create = create
            self._submit = submit
            self._flush = flush
            self._poll = poll
            self._close = close
            self._createWakeupChannel = createWakeupChannel
        }

        // MARK: - Public API

        /// Create a new completion handle.
        public func create() throws(Error) -> Handle {
            try _create()
        }

        /// Submit an operation.
        public func submit(
            _ handle: borrowing Handle,
            operation: borrowing Operation
        ) throws(Error) {
            try _submit(handle, operation)
        }

        /// Flush pending submissions.
        public func flush(_ handle: borrowing Handle) throws(Error) -> Int {
            try _flush(handle)
        }

        /// Poll for completion events.
        public func poll(
            _ handle: borrowing Handle,
            deadline: Deadline?,
            into buffer: inout [Event]
        ) throws(Error) -> Int {
            try _poll(handle, deadline, &buffer)
        }

        /// Close the handle.
        public func close(_ handle: consuming Handle) {
            _close(handle)
        }

        /// Create a wakeup channel.
        public func createWakeupChannel(_ handle: borrowing Handle) throws(Error) -> Wakeup.Channel {
            try _createWakeupChannel(handle)
        }
    }
}

// MARK: - Deadline

extension IO.Completion {
    /// A point in time for timeout calculations.
    ///
    /// Deadlines are used instead of durations to avoid drift
    /// when poll is interrupted and restarted.
    ///
    /// ## Clock
    ///
    /// Uses monotonic time (`CLOCK_MONOTONIC` on POSIX systems) to ensure
    /// consistent timing regardless of system clock adjustments.
    public struct Deadline: Sendable, Comparable {
        /// Nanoseconds since an arbitrary epoch (typically system boot).
        public let nanoseconds: UInt64

        /// Creates a deadline at the given nanosecond value.
        @inlinable
        public init(nanoseconds: UInt64) {
            self.nanoseconds = nanoseconds
        }

        /// A deadline in the infinite future (no timeout).
        public static let never = Deadline(nanoseconds: .max)

        // MARK: - Clock Helpers

        /// The current monotonic time as a deadline.
        public static var now: Deadline {
            Deadline(nanoseconds: monotonicNanoseconds())
        }

        /// Creates a deadline at a given duration from now.
        ///
        /// - Parameter nanoseconds: Duration from now in nanoseconds.
        /// - Returns: A deadline at `now + nanoseconds`.
        public static func after(nanoseconds: Int64) -> Deadline {
            let current = monotonicNanoseconds()
            if nanoseconds <= 0 {
                return Deadline(nanoseconds: current)
            }
            // Saturating add to avoid overflow
            let result = current.addingReportingOverflow(UInt64(nanoseconds))
            return Deadline(nanoseconds: result.overflow ? .max : result.partialValue)
        }

        /// Creates a deadline at a given duration from now.
        ///
        /// - Parameter milliseconds: Duration from now in milliseconds.
        /// - Returns: A deadline at `now + milliseconds`.
        public static func after(milliseconds: Int64) -> Deadline {
            after(nanoseconds: milliseconds * 1_000_000)
        }

        /// Whether this deadline has passed.
        public var hasExpired: Bool {
            Self.monotonicNanoseconds() >= nanoseconds
        }

        /// Nanoseconds remaining until deadline, or 0 if expired.
        public var remainingNanoseconds: Int64 {
            let current = Self.monotonicNanoseconds()
            if current >= nanoseconds {
                return 0
            }
            return Int64(nanoseconds - current)
        }

        // MARK: - Comparable

        public static func < (lhs: Deadline, rhs: Deadline) -> Bool {
            lhs.nanoseconds < rhs.nanoseconds
        }

        // MARK: - Private

        /// Gets the current monotonic time in nanoseconds.
        private static func monotonicNanoseconds() -> UInt64 {
            #if os(Windows)
            var counter = LARGE_INTEGER()
            var frequency = LARGE_INTEGER()
            QueryPerformanceCounter(&counter)
            QueryPerformanceFrequency(&frequency)
            // Convert to nanoseconds
            let seconds = counter.QuadPart / frequency.QuadPart
            let remainder = counter.QuadPart % frequency.QuadPart
            return UInt64(seconds) * 1_000_000_000 + UInt64(remainder * 1_000_000_000 / frequency.QuadPart)
            #else
            var ts = timespec()
            clock_gettime(CLOCK_MONOTONIC, &ts)
            return UInt64(ts.tv_sec) * 1_000_000_000 + UInt64(ts.tv_nsec)
            #endif
        }
    }
}
