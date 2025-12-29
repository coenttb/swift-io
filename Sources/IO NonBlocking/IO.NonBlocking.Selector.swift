//
//  IO.NonBlocking.Selector.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 28/12/2025.
//

@_exported public import IO_NonBlocking_Driver
internal import IO_Blocking


extension IO.NonBlocking {
    /// The central runtime for non-blocking I/O operations.
    ///
    /// The Selector actor manages:
    /// - Registration of file descriptors for readiness notification
    /// - Waiter queues for async operations
    /// - Permit storage for readiness-before-arm scenarios
    /// - Communication with the poll thread
    ///
    /// ## Architecture
    ///
    /// The Selector uses a split architecture:
    /// - **Selector actor**: Runs on an `IO.Executor.Thread`, manages state
    /// - **Poll thread**: Dedicated OS thread, owns driver handle, blocks in poll
    ///
    /// Communication between them uses thread-safe primitives:
    /// - `Event.Bridge`: poll thread → selector (events)
    /// - `Registration.Queue`: selector → poll thread (requests)
    /// - `Wakeup.Channel`: selector → poll thread (signal)
    ///
    /// ## Thread Safety
    ///
    /// The actor is pinned to a custom `IO.Executor.Thread` for predictable
    /// scheduling. All state mutations and continuation resumptions happen
    /// on this executor.
    ///
    /// ## Usage
    /// ```swift
    /// let selector = try IO.NonBlocking.Selector.make()
    /// let (id, token) = try await selector.register(fd, interest: .read)
    /// let (armed, event) = try await selector.arm(token)
    /// // event.interest contains what's ready
    /// ```
    public actor Selector {
        // MARK: - State

        /// The driver (for metadata only - handle is on poll thread).
        private let driver: Driver

        /// Custom executor for this actor.
        private let executor: IO.Executor.Thread

        /// Channel for waking the poll thread.
        private let wakeupChannel: Wakeup.Channel

        /// Bridge for receiving events from poll thread.
        private let eventBridge: Event.Bridge

        /// Queue for sending requests to poll thread.
        private let registrationQueue: IO.NonBlocking.Registration.Queue

        /// Flag for signaling shutdown to poll thread.
        private let shutdownFlag: PollLoop.Shutdown.Flag

        /// Handle to the poll thread.
        private let pollThreadHandle: IO.Thread.Handle

        /// Registration table.
        private var registrations: [ID: Registration] = [:]

        /// Waiter storage keyed by ID.
        private var waiters: [ID: Waiter] = [:]

        /// Permit storage keyed by (ID, Interest).
        private var permits: [PermitKey: Event.Flags] = [:]

        /// Current lifecycle state.
        private var state: LifecycleState = .running

        // MARK: - Custom Executor

        nonisolated public var unownedExecutor: UnownedSerialExecutor {
            executor.asUnownedSerialExecutor()
        }

        /// The executor for this selector.
        public var taskExecutor: any TaskExecutor { executor }

        // MARK: - Initialization

        /// Private memberwise initializer.
        private init(
            driver: Driver,
            executor: IO.Executor.Thread,
            wakeupChannel: Wakeup.Channel,
            eventBridge: Event.Bridge,
            registrationQueue: IO.NonBlocking.Registration.Queue,
            shutdownFlag: PollLoop.Shutdown.Flag,
            pollThreadHandle: IO.Thread.Handle
        ) {
            self.driver = driver
            self.executor = executor
            self.wakeupChannel = wakeupChannel
            self.eventBridge = eventBridge
            self.registrationQueue = registrationQueue
            self.shutdownFlag = shutdownFlag
            self.pollThreadHandle = pollThreadHandle
        }

        /// Create a new selector.
        ///
        /// - Parameters:
        ///   - driver: The driver to use (defaults to platform driver).
        ///   - executor: The executor to pin the actor to.
        /// - Returns: A new selector.
        /// - Throws: If driver handle creation fails.
        public static func make(
            driver: Driver,
            executor: IO.Executor.Thread
        ) throws(Error) -> Selector {
            // Create driver handle
            let handle = try driver.create()

            // Create wakeup channel
            let wakeupChannel = try driver.createWakeupChannel(handle)

            // Create communication primitives
            let eventBridge = Event.Bridge()
            let registrationQueue = IO.NonBlocking.Registration.Queue()
            let shutdownFlag = PollLoop.Shutdown.Flag()

            // Create context for poll thread
            let context = PollLoop.Context(
                driver: driver,
                handle: handle,
                eventBridge: eventBridge,
                registrationQueue: registrationQueue,
                shutdownFlag: shutdownFlag
            )

            // Start poll thread with context
            let pollThreadHandle = IO.Thread.spawn(context) { context in
                PollLoop.run(context)
            }

            return Selector(
                driver: driver,
                executor: executor,
                wakeupChannel: wakeupChannel,
                eventBridge: eventBridge,
                registrationQueue: registrationQueue,
                shutdownFlag: shutdownFlag,
                pollThreadHandle: pollThreadHandle
            )
        }

        // MARK: - Registration API

        /// Register a descriptor for readiness notification.
        ///
        /// - Parameters:
        ///   - descriptor: The file descriptor to register.
        ///   - interest: The interests to monitor.
        /// - Returns: The registration ID and a token for arming.
        /// - Throws: If shutdown is in progress or registration fails.
        public func register(
            _ descriptor: Int32,
            interest: Interest
        ) async throws(Failure) -> Register.Result {
            guard state == .running else {
                throw .shutdownInProgress
            }

            // Enqueue request to poll thread
            let result: Result<ID, Error> = await withCheckedContinuation { continuation in
                let request = IO.NonBlocking.Registration.Request.register(
                    descriptor: descriptor,
                    interest: interest,
                    continuation: continuation
                )
                registrationQueue.enqueue(request)
                wakeupChannel.wake()
            }

            switch result {
            case .success(let id):
                registrations[id] = Registration(descriptor: descriptor, interest: interest)
                return Register.Result(id: id, token: Token(id: id))
            case .failure(let error):
                throw .failure(error)
            }
        }

        /// Arm a registration to wait for readiness.
        ///
        /// - Parameter token: The registration token (consumed).
        /// - Returns: An armed token and the event when ready.
        /// - Throws: If shutdown or cancelled.
        public func arm(
            _ token: consuming Token<Registering>
        ) async throws(Failure) -> Arm.Result {
            let id = token.id

            guard state == .running else {
                throw .shutdownInProgress
            }

            // Check for existing permit
            for interest in [Interest.read, .write, .priority] {
                let key = PermitKey(id: id, interest: interest)
                if let flags = permits.removeValue(forKey: key) {
                    let event = Event(id: id, interest: interest, flags: flags)
                    return Arm.Result(token: Token(id: id), event: event)
                }
            }

            // No permit - create waiter and wait with cancellation support
            //
            // Cancellation model (mirrors IO.Handle.Waiter):
            // - cancel() flips state synchronously from onCancel handler
            // - cancel() triggers wakeup so actor drains on next touch
            // - Actor is the single resumption funnel
            //
            // Uses non-throwing continuation with Result payload to achieve
            // typed errors without any existential error handling.
            let waiter = Waiter(id: id)

            // Capture wakeup channel for cancellation handler
            let wakeup = wakeupChannel

            let result: Result<Event, Failure> = await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    let armed = waiter.arm(continuation: continuation)
                    precondition(armed, "Waiter must arm exactly once before insertion")
                    waiters[id] = waiter
                }
            } onCancel: {
                // Sync flip only - never resume from onCancel
                waiter.cancel()
                // Trigger a touch so actor drains cancelled waiters
                wakeup.wake()
            }

            switch result {
            case .success(let event):
                return Arm.Result(token: Token(id: id), event: event)
            case .failure(let failure):
                throw failure
            }
        }

        /// Deregister a descriptor.
        ///
        /// - Parameter token: The armed token (consumed).
        /// - Throws: If deregistration fails.
        public func deregister(
            _ token: consuming Token<Armed>
        ) async throws(Failure) {
            let id = token.id

            // Remove from local state
            registrations.removeValue(forKey: id)

            // Drain any armed waiter with .deregistered error
            // Never drop a waiter - always resume with deterministic outcome
            if let waiter = waiters.removeValue(forKey: id) {
                if let (continuation, _) = waiter.takeForResume() {
                    continuation.resume(returning: .failure(.failure(.deregistered)))
                }
            }

            // Remove permits for this ID
            for interest in [Interest.read, .write, .priority] {
                permits.removeValue(forKey: PermitKey(id: id, interest: interest))
            }

            // Request deregistration from poll thread
            let result: Result<Void, Error> = await withCheckedContinuation { continuation in
                let request = IO.NonBlocking.Registration.Request.deregister(
                    id: id,
                    continuation: continuation
                )
                registrationQueue.enqueue(request)
                wakeupChannel.wake()
            }

            if case .failure(let error) = result {
                throw .failure(error)
            }
        }

        // MARK: - Event Processing

        /// Run the event processing loop.
        ///
        /// This method processes events from the poll thread and resumes
        /// waiting continuations.
        public func runEventLoop() async {
            while let batch = await eventBridge.next() {
                for event in batch {
                    processEvent(event)
                }
                // Drain any waiters that were cancelled during this touch
                drainCancelledWaiters()
            }
            // Bridge returned nil = shutdown
        }

        /// Drain all cancelled waiters.
        ///
        /// Called after each event batch to ensure cancelled waiters are resumed
        /// promptly. The cancellation handler triggers a wakeup to ensure the
        /// actor touches this method even if no events are pending.
        private func drainCancelledWaiters() {
            for (id, waiter) in waiters where waiter.wasCancelled {
                waiters.removeValue(forKey: id)
                if let (continuation, _) = waiter.takeForResume() {
                    continuation.resume(returning: .failure(.cancelled))
                }
            }
        }

        private func processEvent(_ event: Event) {
            // For each interest bit in the event
            for interest in [Interest.read, .write, .priority] where event.interest.contains(interest) {
                if let waiter = waiters.removeValue(forKey: event.id) {
                    // Drain the waiter using state machine
                    if let (continuation, wasCancelled) = waiter.takeForResume() {
                        if wasCancelled {
                            continuation.resume(returning: .failure(.cancelled))
                        } else {
                            continuation.resume(returning: .success(event))
                        }
                    }
                } else {
                    // Store as permit
                    let key = PermitKey(id: event.id, interest: interest)
                    permits[key] = event.flags
                }
            }
        }

        // MARK: - Lifecycle

        /// Shutdown the selector.
        public func shutdown() async {
            guard state == .running else { return }
            state = .shuttingDown

            // Signal shutdown to poll thread
            shutdownFlag.set()
            wakeupChannel.wake()

            // Drain all waiters with shutdown error using state machine
            for (_, waiter) in waiters {
                if let (continuation, _) = waiter.takeForResume() {
                    // Regardless of cancellation status, shutdown takes precedence
                    continuation.resume(returning: .failure(.shutdownInProgress))
                }
            }
            waiters.removeAll()

            // Enqueue deregistrations for all remaining registrations
            for id in registrations.keys {
                registrationQueue.enqueue(IO.NonBlocking.Registration.Request.deregister(id: id, continuation: nil))
            }
            registrations.removeAll()

            // Signal shutdown to event bridge
            eventBridge.shutdown()

            // Wait for poll thread to complete
            pollThreadHandle.join()

            state = .shutdown
        }
    }
}

// MARK: - Supporting Types

extension IO.NonBlocking.Selector {
    /// Lifecycle state of the selector.
    enum LifecycleState {
        case running
        case shuttingDown
        case shutdown
    }

    /// A registered descriptor.
    struct Registration {
        let descriptor: Int32
        var interest: IO.NonBlocking.Interest
    }

    /// Key for permit storage.
    struct PermitKey: Hashable {
        let id: IO.NonBlocking.ID
        let interest: IO.NonBlocking.Interest
    }
}

// MARK: - Result Types

extension IO.NonBlocking {
    /// Namespace for registration-related types.
    public enum Register {
        /// Result of registering a descriptor.
        ///
        /// Contains the registration ID and a token for arming.
        /// This struct is ~Copyable because it contains a move-only Token.
        public struct Result: ~Copyable, Sendable {
            /// The registration ID.
            public let id: ID

            /// Token for arming the registration.
            public var token: Token<Registering>

            @usableFromInline
            package init(id: ID, token: consuming Token<Registering>) {
                self.id = id
                self.token = token
            }
        }
    }

    /// Namespace for arm-related types.
    public enum Arm {
        /// Result of arming a registration.
        ///
        /// Contains an armed token and the event that triggered it.
        /// This struct is ~Copyable because it contains a move-only Token.
        public struct Result: ~Copyable, Sendable {
            /// Token for modifying, deregistering, or cancelling.
            public var token: Token<Armed>

            /// The event that triggered readiness.
            public let event: Event

            @usableFromInline
            package init(token: consuming Token<Armed>, event: Event) {
                self.token = token
                self.event = event
            }
        }
    }
}
