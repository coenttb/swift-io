//
//  IO.Completion.Driver.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 31/12/2025.
//


public import Dimension
public import Kernel

extension IO.Completion {
    /// Protocol witness struct for platform-specific completion backends.
    ///
    /// The Driver provides a uniform interface over platform-specific
    /// completion mechanisms:
    /// - **Windows**: IOCP (I/O Completion Ports)
    /// - **Linux**: io_uring
    /// - **Darwin**: Not supported (use IO.Events with kqueue instead)
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

        /// Submit operation storage to the completion backend.
        ///
        /// Called from poll thread only. This is the primary submit witness.
        /// Takes `Operation.Storage` directly, allowing the poll thread to
        /// drain the `Submission.Queue` and submit storages without
        /// reconstructing `Operation` wrappers.
        let _submitStorage:
            @Sendable (
                borrowing Handle,
                Operation.Storage
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
        let _poll:
            @Sendable (
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
        let _createWakeupChannel: @Sendable (borrowing Handle) throws(Error) -> Wakeup.Channel

        // MARK: - Initialization

        /// Creates a driver with the given witness closures.
        ///
        /// - Parameters:
        ///   - capabilities: Backend capabilities.
        ///   - create: Creates a new completion handle.
        ///   - submitStorage: Submits operation storage to the backend.
        ///   - flush: Flushes pending submissions.
        ///   - poll: Waits for completion events.
        ///   - close: Closes the handle.
        ///   - createWakeupChannel: Creates a wakeup channel.
        public init(
            capabilities: Capabilities,
            create: @escaping @Sendable () throws(Error) -> Handle,
            submitStorage: @escaping @Sendable (borrowing Handle, Operation.Storage) throws(Error) -> Void,
            flush: @escaping @Sendable (borrowing Handle) throws(Error) -> Int,
            poll: @escaping @Sendable (borrowing Handle, Deadline?, inout [Event]) throws(Error) -> Int,
            close: @escaping @Sendable (consuming Handle) -> Void,
            createWakeupChannel: @escaping @Sendable (borrowing Handle) throws(Error) -> Wakeup.Channel
        ) {
            self.capabilities = capabilities
            self._create = create
            self._submitStorage = submitStorage
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
        ///
        /// Convenience API that extracts storage from the operation.
        /// For direct storage submission (used by poll loop), use
        /// `submit(_:storage:)` instead.
        public func submit(
            _ handle: borrowing Handle,
            operation: consuming Operation
        ) throws(Error) {
            try _submitStorage(handle, operation.storage)
        }

        /// Submit operation storage directly.
        ///
        /// Primary submit API used by the poll loop after draining
        /// the submission queue.
        public func submit(
            _ handle: borrowing Handle,
            storage: Operation.Storage
        ) throws(Error) {
            try _submitStorage(handle, storage)
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
