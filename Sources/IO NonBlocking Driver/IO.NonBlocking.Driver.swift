//
//  IO.NonBlocking.Driver.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 28/12/2025.
//

@_exported public import IO_NonBlocking_Primitives

extension IO.NonBlocking {
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
    /// let driver = IO.NonBlocking.Driver.platform
    /// let handle = try driver.create()
    /// let wakeupChannel = try driver.createWakeupChannel(handle)
    /// // Transfer handle to poll thread, keep wakeupChannel for selector
    /// ```
    public struct Driver: Sendable {
        /// Capabilities of this driver backend.
        public let capabilities: Capabilities

        // MARK: - Witness Closures

        /// Create a new selector handle.
        private let _create: @Sendable () throws -> Handle

        /// Register a descriptor for the given interests.
        ///
        /// Called from poll thread only.
        private let _register: @Sendable (
            borrowing Handle,
            Int32,  // Raw file descriptor
            Interest
        ) throws -> ID

        /// Modify the interests for a registered descriptor.
        ///
        /// Called from poll thread only.
        private let _modify: @Sendable (
            borrowing Handle,
            ID,
            Interest
        ) throws -> Void

        /// Remove a descriptor from the selector.
        ///
        /// Called from poll thread only.
        private let _deregister: @Sendable (
            borrowing Handle,
            ID
        ) throws -> Void

        /// Wait for events with optional timeout.
        ///
        /// Called from poll thread only. This is the blocking call.
        ///
        /// - Parameters:
        ///   - handle: The selector handle
        ///   - deadline: Optional timeout deadline
        ///   - buffer: Pre-allocated event buffer
        /// - Returns: Number of events written to buffer
        private let _poll: @Sendable (
            borrowing Handle,
            Deadline?,
            inout [Event]
        ) throws -> Int

        /// Close the selector handle.
        ///
        /// Called from poll thread only. Consumes the handle.
        private let _close: @Sendable (consuming Handle) -> Void

        /// Create a wakeup channel for this handle.
        ///
        /// The returned channel is `Sendable` and can be used from any thread
        /// to wake the poll thread. Uses platform-specific primitives:
        /// - kqueue: `EVFILT_USER`
        /// - epoll: `eventfd`
        /// - IOCP: `PostQueuedCompletionStatus`
        private let _createWakeupChannel: @Sendable (borrowing Handle) throws -> Wakeup.Channel

        // MARK: - Initialization

        /// Creates a driver with the given witness closures.
        public init(
            capabilities: Capabilities,
            create: @escaping @Sendable () throws -> Handle,
            register: @escaping @Sendable (borrowing Handle, Int32, Interest) throws -> ID,
            modify: @escaping @Sendable (borrowing Handle, ID, Interest) throws -> Void,
            deregister: @escaping @Sendable (borrowing Handle, ID) throws -> Void,
            poll: @escaping @Sendable (borrowing Handle, Deadline?, inout [Event]) throws -> Int,
            close: @escaping @Sendable (consuming Handle) -> Void,
            createWakeupChannel: @escaping @Sendable (borrowing Handle) throws -> Wakeup.Channel
        ) {
            self.capabilities = capabilities
            self._create = create
            self._register = register
            self._modify = modify
            self._deregister = deregister
            self._poll = poll
            self._close = close
            self._createWakeupChannel = createWakeupChannel
        }

        // MARK: - Public API

        /// Create a new selector handle.
        public func create() throws -> Handle {
            try _create()
        }

        /// Register a descriptor.
        public func register(
            _ handle: borrowing Handle,
            descriptor: Int32,
            interest: Interest
        ) throws -> ID {
            try _register(handle, descriptor, interest)
        }

        /// Modify registration interests.
        public func modify(
            _ handle: borrowing Handle,
            id: ID,
            interest: Interest
        ) throws {
            try _modify(handle, id, interest)
        }

        /// Deregister a descriptor.
        public func deregister(
            _ handle: borrowing Handle,
            id: ID
        ) throws {
            try _deregister(handle, id)
        }

        /// Poll for events.
        public func poll(
            _ handle: borrowing Handle,
            deadline: Deadline?,
            into buffer: inout [Event]
        ) throws -> Int {
            try _poll(handle, deadline, &buffer)
        }

        /// Close the handle.
        public func close(_ handle: consuming Handle) {
            _close(handle)
        }

        /// Create a wakeup channel.
        public func createWakeupChannel(_ handle: borrowing Handle) throws -> Wakeup.Channel {
            try _createWakeupChannel(handle)
        }
    }
}

// MARK: - Deadline

extension IO.NonBlocking {
    /// A point in time for timeout calculations.
    ///
    /// Deadlines are used instead of durations to avoid drift
    /// when poll is interrupted and restarted.
    public struct Deadline: Sendable {
        /// Nanoseconds since an arbitrary epoch (typically system boot).
        public let nanoseconds: UInt64

        /// Creates a deadline at the given nanosecond value.
        public init(nanoseconds: UInt64) {
            self.nanoseconds = nanoseconds
        }

        /// A deadline in the infinite future (no timeout).
        public static let never = Deadline(nanoseconds: .max)
    }
}
