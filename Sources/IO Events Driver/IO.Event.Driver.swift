//
//  IO.Event.Driver.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 28/12/2025.
//

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#elseif os(Windows)
    import WinSDK
#endif

@_exported public import IO_Events_Primitives

extension IO.Event {
    /// Protocol witness struct for platform-specific selector backends.
    ///
    /// The Driver provides a uniform interface over platform-specific
    /// event notification mechanisms:
    /// - **Darwin**: kqueue
    /// - **Linux**: epoll
    /// - **Windows**: IOCP (I/O Completion Ports)
    ///
    /// ## Thread Safety Model
    ///
    /// All driver operations are invoked **only on the poll thread**.
    /// The selector actor never touches the driver handle directly.
    /// Communication between selector and poll thread uses thread-safe
    /// primitives: `Event.Bridge`, `Wakeup.Channel`, `Registration.Queue`.
    ///
    /// ## Ownership
    ///
    /// - `Handle` is `~Copyable` and owned by the poll thread
    /// - `_close` consumes the handle; all other operations borrow it
    /// - `Wakeup.Channel` is created separately and is `Sendable`
    ///
    /// ## Usage
    /// ```swift
    /// let driver = IO.Event.Driver.platform
    /// let handle = try driver.create()
    /// let wakeupChannel = try driver.createWakeupChannel(handle)
    /// // Transfer handle to poll thread, keep wakeupChannel for selector
    /// ```
    public struct Driver: Sendable {
        /// Capabilities of this driver backend.
        public let capabilities: Capabilities

        // MARK: - Witness Closures

        /// Create a new selector handle.
        let _create: @Sendable () throws(Error) -> Handle

        /// Register a descriptor for the given interests.
        ///
        /// Called from poll thread only.
        let _register: @Sendable (
            borrowing Handle,
            Int32,  // Raw file descriptor
            Interest
        ) throws(Error) -> ID

        /// Modify the interests for a registered descriptor.
        ///
        /// Called from poll thread only.
        let _modify: @Sendable (
            borrowing Handle,
            ID,
            Interest
        ) throws(Error) -> Void

        /// Remove a descriptor from the selector.
        ///
        /// Called from poll thread only.
        let _deregister: @Sendable (
            borrowing Handle,
            ID
        ) throws(Error) -> Void

        /// Arm a registration for readiness notification.
        ///
        /// Enables the kernel filter for the specified interest. With one-shot
        /// semantics (EV_DISPATCH on kqueue, EPOLLONESHOT on epoll), the filter
        /// is automatically disabled after delivering an event.
        ///
        /// Called from poll thread only.
        let _arm: @Sendable (
            borrowing Handle,
            ID,
            Interest
        ) throws(Error) -> Void

        /// Wait for events with optional timeout.
        ///
        /// Called from poll thread only. This is the blocking call.
        ///
        /// - Parameters:
        ///   - handle: The selector handle
        ///   - deadline: Optional timeout deadline
        ///   - buffer: Pre-allocated event buffer
        /// - Returns: Number of events written to buffer
        let _poll: @Sendable (
            borrowing Handle,
            Deadline?,
            inout [IO.Event]
        ) throws(Error) -> Int

        /// Close the selector handle.
        ///
        /// Called from poll thread only. Consumes the handle.
        let _close: @Sendable (consuming Handle) -> Void

        /// Create a wakeup channel for this handle.
        ///
        /// The returned channel is `Sendable` and can be used from any thread
        /// to wake the poll thread. Uses platform-specific primitives:
        /// - kqueue: `EVFILT_USER`
        /// - epoll: `eventfd`
        /// - IOCP: `PostQueuedCompletionStatus`
        let _createWakeupChannel: @Sendable (borrowing Handle) throws(Error) -> Wakeup.Channel

        // MARK: - Initialization

        /// Creates a driver with the given witness closures.
        public init(
            capabilities: Capabilities,
            create: @escaping @Sendable () throws(Error) -> Handle,
            register: @escaping @Sendable (borrowing Handle, Int32, Interest) throws(Error) -> ID,
            modify: @escaping @Sendable (borrowing Handle, ID, Interest) throws(Error) -> Void,
            deregister: @escaping @Sendable (borrowing Handle, ID) throws(Error) -> Void,
            arm: @escaping @Sendable (borrowing Handle, ID, Interest) throws(Error) -> Void,
            poll: @escaping @Sendable (borrowing Handle, Deadline?, inout [IO.Event]) throws(Error) -> Int,
            close: @escaping @Sendable (consuming Handle) -> Void,
            createWakeupChannel: @escaping @Sendable (borrowing Handle) throws(Error) -> Wakeup.Channel
        ) {
            self.capabilities = capabilities
            self._create = create
            self._register = register
            self._modify = modify
            self._deregister = deregister
            self._arm = arm
            self._poll = poll
            self._close = close
            self._createWakeupChannel = createWakeupChannel
        }

        // MARK: - Public API

        /// Create a new selector handle.
        public func create() throws(Error) -> Handle {
            try _create()
        }

        /// Register a descriptor.
        public func register(
            _ handle: borrowing Handle,
            descriptor: Int32,
            interest: Interest
        ) throws(Error) -> ID {
            try _register(handle, descriptor, interest)
        }

        /// Modify registration interests.
        public func modify(
            _ handle: borrowing Handle,
            id: ID,
            interest: Interest
        ) throws(Error) {
            try _modify(handle, id, interest)
        }

        /// Deregister a descriptor.
        public func deregister(
            _ handle: borrowing Handle,
            id: ID
        ) throws(Error) {
            try _deregister(handle, id)
        }

        /// Arm a registration for readiness notification.
        ///
        /// Enables the kernel filter for the specified interest. With one-shot
        /// semantics, the filter is automatically disabled after delivering an event.
        public func arm(
            _ handle: borrowing Handle,
            id: ID,
            interest: Interest
        ) throws(Error) {
            try _arm(handle, id, interest)
        }

        /// Poll for events.
        public func poll(
            _ handle: borrowing Handle,
            deadline: Deadline?,
            into buffer: inout [IO.Event]
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

extension IO.Event {
    /// A point in time for timeout calculations.
    ///
    /// Deadlines are used instead of durations to avoid drift
    /// when poll is interrupted and restarted.
    ///
    /// ## Clock
    /// Uses monotonic time (`CLOCK_MONOTONIC` on POSIX systems) to ensure
    /// consistent timing regardless of system clock adjustments.
    public struct Deadline: Sendable, Comparable {
        /// Nanoseconds since an arbitrary epoch (typically system boot).
        public let nanoseconds: UInt64

        /// Creates a deadline at the given nanosecond value.
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
            var counter: LARGE_INTEGER = LARGE_INTEGER()
            var frequency: LARGE_INTEGER = LARGE_INTEGER()
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
