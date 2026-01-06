//
//  IO.Event.Driver.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 28/12/2025.
//

import Kernel

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
        let _register:
            @Sendable (
                borrowing Handle,
                Int32,  // Raw file descriptor
                Interest
            ) throws(Error) -> ID

        /// Modify the interests for a registered descriptor.
        ///
        /// Called from poll thread only.
        let _modify:
            @Sendable (
                borrowing Handle,
                ID,
                Interest
            ) throws(Error) -> Void

        /// Remove a descriptor from the selector.
        ///
        /// Called from poll thread only.
        let _deregister:
            @Sendable (
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
        let _arm:
            @Sendable (
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
        let _poll:
            @Sendable (
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
    /// Alias to `Kernel.Time.Deadline`. Convenience extensions in this package
    /// add `hasExpired`, `remainingNanoseconds`, and `remaining` properties.
    public typealias Deadline = Tagged<Self, Kernel.Time.Deadline>
}


#if canImport(Darwin)

extension IO.Event.Driver {
    /// Creates a kqueue-based driver.
    ///
    /// - Returns: A driver configured for kqueue operations.
    public static func kqueue() -> IO.Event.Driver {
        IO.Event.Driver(
            capabilities: IO.Event.Driver.Capabilities(
                maxEvents: 256,
                supportsEdgeTriggered: true,
                isCompletionBased: false
            ),
            create: IO.Event.Queue.Operations.create,
            register: IO.Event.Queue.Operations.register,
            modify: IO.Event.Queue.Operations.modify,
            deregister: IO.Event.Queue.Operations.deregister,
            arm: IO.Event.Queue.Operations.arm,
            poll: IO.Event.Queue.Operations.poll,
            close: IO.Event.Queue.Operations.close,
            createWakeupChannel: IO.Event.Queue.Operations.createWakeupChannel
        )
    }
}

#endif

#if canImport(Glibc)

extension IO.Event.Driver {
    /// Creates an epoll-based driver.
    ///
    /// - Returns: A driver configured for epoll operations.
    public static func epoll() -> IO.Event.Driver {
        IO.Event.Driver(
            capabilities: IO.Event.Driver.Capabilities(
                maxEvents: 256,
                supportsEdgeTriggered: true,
                isCompletionBased: false
            ),
            create: IO.Event.Poll.Operations.create,
            register: IO.Event.Poll.Operations.register,
            modify: IO.Event.Poll.Operations.modify,
            deregister: IO.Event.Poll.Operations.deregister,
            arm: IO.Event.Poll.Operations.arm,
            poll: IO.Event.Poll.Operations.poll,
            close: IO.Event.Poll.Operations.close,
            createWakeupChannel: IO.Event.Poll.Operations.createWakeupChannel
        )
    }
}

#endif
