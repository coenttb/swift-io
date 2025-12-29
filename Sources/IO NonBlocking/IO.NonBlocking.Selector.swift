//
//  IO.NonBlocking.Selector.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 28/12/2025.
//

@_exported public import IO_NonBlocking_Driver


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
    /// - `Registration.Reply.Bridge`: poll thread → selector (registration replies)
    /// - `Registration.Queue`: selector → poll thread (requests)
    /// - `Wakeup.Channel`: selector → poll thread (signal)
    ///
    /// ## Single Resumption Funnel
    ///
    /// All continuations are resumed on the selector executor. The poll thread
    /// never resumes continuations directly - it pushes replies to bridges.
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

        /// Bridge for receiving registration replies from poll thread.
        private let replyBridge: IO.NonBlocking.Registration.Reply.Bridge

        /// Queue for sending requests to poll thread.
        private let registrationQueue: IO.NonBlocking.Registration.Queue

        /// Flag for signaling shutdown to poll thread.
        private let shutdownFlag: PollLoop.Shutdown.Flag

        /// Handle to the poll thread.
        private let pollThreadHandle: IO.Thread.Handle

        /// Registration table.
        private var registrations: [ID: Registration] = [:]

        /// Waiter storage keyed by (ID, Interest).
        private var waiters: [PermitKey: Waiter] = [:]

        /// Permit storage keyed by (ID, Interest).
        private var permits: [PermitKey: Event.Flags] = [:]

        /// Current lifecycle state.
        private var state: LifecycleState = .running

        /// Pending registration reply continuations keyed by ReplyID.
        ///
        /// Selector owns these continuations and resumes them when replies arrive.
        /// This enforces the single resumption funnel invariant.
        ///
        /// Uses typed `Failure` (not untyped `Error`) to maintain lifecycle discipline:
        /// - Poll thread produces `Result<Payload, IO.NonBlocking.Error>` (leaf errors)
        /// - Selector wraps leaf errors in `.failure(.failure(leaf))`
        /// - Shutdown drains with `.failure(.shutdownInProgress)` (lifecycle error)
        private var pendingReplies: [IO.NonBlocking.Registration.ReplyID: CheckedContinuation<Result<IO.NonBlocking.Registration.Payload, Failure>, Never>] = [:]

        /// Counter for generating reply IDs.
        private var nextReplyID: UInt64 = 0

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
            replyBridge: IO.NonBlocking.Registration.Reply.Bridge,
            registrationQueue: IO.NonBlocking.Registration.Queue,
            shutdownFlag: PollLoop.Shutdown.Flag,
            pollThreadHandle: IO.Thread.Handle
        ) {
            self.driver = driver
            self.executor = executor
            self.wakeupChannel = wakeupChannel
            self.eventBridge = eventBridge
            self.replyBridge = replyBridge
            self.registrationQueue = registrationQueue
            self.shutdownFlag = shutdownFlag
            self.pollThreadHandle = pollThreadHandle
        }

        /// Create and start a new selector.
        ///
        /// The selector is fully initialized and ready for I/O operations upon return.
        /// Event and reply processing loops are started automatically.
        ///
        /// - Parameters:
        ///   - driver: The driver to use (defaults to platform driver).
        ///   - executor: The executor to pin the actor to.
        /// - Returns: A new, running selector.
        /// - Throws: `Make.Error` if construction fails.
        public static func make(
            driver: Driver,
            executor: IO.Executor.Thread
        ) async throws(Make.Error) -> Selector {
            // Create driver handle and wakeup channel
            // Uses typed conversion helper - no existential widening, no `as` casts
            // Explicit closure types required because Swift doesn't infer typed-throws in closures
            let handle = try Make.Error.driver {
                () throws(IO.NonBlocking.Error) -> Driver.Handle in try driver.create()
            }
            let wakeupChannel = try Make.Error.driver {
                () throws(IO.NonBlocking.Error) -> Wakeup.Channel in try driver.createWakeupChannel(handle)
            }

            // Create communication primitives
            let eventBridge = Event.Bridge()
            let replyBridge = IO.NonBlocking.Registration.Reply.Bridge()
            let registrationQueue = IO.NonBlocking.Registration.Queue()
            let shutdownFlag = PollLoop.Shutdown.Flag()

            // Create context for poll thread
            let context = PollLoop.Context(
                driver: driver,
                handle: handle,
                eventBridge: eventBridge,
                replyBridge: replyBridge,
                registrationQueue: registrationQueue,
                shutdownFlag: shutdownFlag
            )

            // Start poll thread with context
            let pollThreadHandle = IO.Thread.spawn(context) { context in
                PollLoop.run(context)
            }

            let selector = Selector(
                driver: driver,
                executor: executor,
                wakeupChannel: wakeupChannel,
                eventBridge: eventBridge,
                replyBridge: replyBridge,
                registrationQueue: registrationQueue,
                shutdownFlag: shutdownFlag,
                pollThreadHandle: pollThreadHandle
            )

            // Start event and reply loops - enforced by construction
            // await is for actor isolation, start() itself is synchronous (spawns Tasks)
            await selector.start()

            return selector
        }

        // MARK: - Lifecycle Control

        /// Start the selector's event and reply processing loops.
        ///
        /// This method starts two concurrent tasks:
        /// - Event loop: Processes events from the poll thread
        /// - Reply loop: Processes registration replies from the poll thread
        ///
        /// Both loops run on the selector's executor and exit when shutdown is called.
        /// Called automatically by `make()` - not for external use.
        private func start() {
            Task { await self.runEventLoop() }
            Task { await self.runReplyLoop() }
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

            // Generate reply ID for matching request to reply
            let replyID = IO.NonBlocking.Registration.ReplyID(raw: nextReplyID)
            nextReplyID &+= 1  // Wrapping add OK

            // Store continuation and enqueue request
            let result: Result<IO.NonBlocking.Registration.Payload, Failure> = await withCheckedContinuation { continuation in
                pendingReplies[replyID] = continuation
                let request = IO.NonBlocking.Registration.Request.register(
                    descriptor: descriptor,
                    interest: interest,
                    replyID: replyID
                )
                registrationQueue.enqueue(request)
                wakeupChannel.wake()
            }

            switch result {
            case .success(.registered(let id)):
                registrations[id] = Registration(descriptor: descriptor, interest: interest)
                return Register.Result(id: id, token: Token(id: id))
            case .success:
                preconditionFailure("Expected .registered payload for register request")
            case .failure(let failure):
                throw failure
            }
        }

        // MARK: - Token-Preserving Arm (Internal Power Tool)

        /// Arm a registration, preserving the token on failure.
        ///
        /// This is the internal "power tool" that returns an `Outcome` enum,
        /// making token loss unrepresentable. Channel uses this exclusively.
        ///
        /// - Parameters:
        ///   - token: The registration token (consumed).
        ///   - interest: The interest to wait for (read, write, or priority).
        /// - Returns: `.armed(result)` on success, `.failed(token:failure:)` on failure.
        public func armPreservingToken(
            _ token: consuming Token<Registering>,
            interest: Interest
        ) async -> Arm.Registering.Outcome {
            do {
                let result = try await arm(id: token.id, interest: interest)
                return .armed(result)
            } catch let failure {
                return .failed(token: token, failure: failure)
            }
        }

        /// Re-arm a registration, preserving the token on failure.
        ///
        /// This is the internal "power tool" that returns an `Outcome` enum,
        /// making token loss unrepresentable. Channel uses this exclusively.
        ///
        /// - Parameters:
        ///   - token: The armed token (consumed).
        ///   - interest: The interest to wait for (read, write, or priority).
        /// - Returns: `.armed(result)` on success, `.failed(token:failure:)` on failure.
        public func armPreservingToken(
            _ token: consuming Token<Armed>,
            interest: Interest
        ) async -> Arm.Armed.Outcome {
            do {
                let result = try await arm(id: token.id, interest: interest)
                return .armed(result)
            } catch let failure {
                return .failed(token: token, failure: failure)
            }
        }

        // MARK: - Ergonomic Throwing Arm

        /// Arm a registration to wait for readiness with a specific interest.
        ///
        /// - Parameters:
        ///   - token: The registration token (consumed).
        ///   - interest: The interest to wait for (read, write, or priority).
        /// - Returns: An armed token and the event when ready.
        /// - Throws: `Failure` on shutdown or cancellation. Token is lost on failure.
        public func arm(
            _ token: consuming Token<Registering>,
            interest: Interest
        ) async throws(Failure) -> Arm.Result {
            switch await armPreservingToken(consume token, interest: interest) {
            case .armed(let result):
                return result
            case .failed(_, let failure):
                throw failure
            }
        }

        /// Re-arm a registration to wait for readiness with a specific interest.
        ///
        /// This allows Channel loops to re-arm after processing an event.
        ///
        /// - Parameters:
        ///   - token: The armed token (consumed).
        ///   - interest: The interest to wait for (read, write, or priority).
        /// - Returns: An armed token and the event when ready.
        /// - Throws: `Failure` on shutdown or cancellation. Token is lost on failure.
        public func arm(
            _ token: consuming Token<Armed>,
            interest: Interest
        ) async throws(Failure) -> Arm.Result {
            switch await armPreservingToken(consume token, interest: interest) {
            case .armed(let result):
                return result
            case .failed(_, let failure):
                throw failure
            }
        }

        /// Private implementation of interest-specific arming.
        ///
        /// - Parameters:
        ///   - id: The registration ID.
        ///   - interest: The interest to wait for.
        /// - Returns: An armed token and the event when ready.
        /// - Throws: If shutdown or cancelled.
        private func arm(
            id: ID,
            interest: Interest
        ) async throws(Failure) -> Arm.Result {
            guard state == .running else {
                throw .shutdownInProgress
            }

            let key = PermitKey(id: id, interest: interest)

            // Check for existing permit for this specific interest
            if let flags = permits.removeValue(forKey: key) {
                let event = Event(id: id, interest: interest, flags: flags)
                return Arm.Result(token: Token(id: id), event: event)
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
                    waiters[key] = waiter
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

        /// Deregister a descriptor (from armed state).
        ///
        /// - Parameter token: The armed token (consumed).
        /// - Throws: If deregistration fails.
        public func deregister(
            _ token: consuming Token<Armed>
        ) async throws(Failure) {
            try await deregister(id: token.id)
        }

        /// Deregister a descriptor (from registering state).
        ///
        /// Use this when closing a channel that was registered but never armed.
        ///
        /// - Parameter token: The registering token (consumed).
        /// - Throws: If deregistration fails.
        public func deregister(
            _ token: consuming Token<Registering>
        ) async throws(Failure) {
            try await deregister(id: token.id)
        }

        /// Internal deregister implementation.
        private func deregister(id: ID) async throws(Failure) {
            let id = id

            // Remove from local state
            registrations.removeValue(forKey: id)

            // Drain all armed waiters for this ID with .deregistered error
            // Never drop a waiter - always resume with deterministic outcome
            for key in waiters.keys where key.id == id {
                if let waiter = waiters.removeValue(forKey: key),
                   let (continuation, _) = waiter.takeForResume() {
                    continuation.resume(returning: .failure(.failure(.deregistered)))
                }
            }

            // Remove permits for this ID
            for interest in [Interest.read, .write, .priority] {
                permits.removeValue(forKey: PermitKey(id: id, interest: interest))
            }

            // Generate reply ID for matching request to reply
            let replyID = IO.NonBlocking.Registration.ReplyID(raw: nextReplyID)
            nextReplyID &+= 1

            // Store continuation and enqueue request
            let result: Result<IO.NonBlocking.Registration.Payload, Failure> = await withCheckedContinuation { continuation in
                pendingReplies[replyID] = continuation
                let request = IO.NonBlocking.Registration.Request.deregister(
                    id: id,
                    replyID: replyID
                )
                registrationQueue.enqueue(request)
                wakeupChannel.wake()
            }

            if case .failure(let failure) = result {
                throw failure
            }
            // Ignore .success(.deregistered) - operation succeeded
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

        /// Run the registration reply processing loop.
        ///
        /// This method processes registration replies from the poll thread
        /// and resumes the stored continuations on the selector executor.
        /// This enforces the single resumption funnel invariant.
        public func runReplyLoop() async {
            while let reply = await replyBridge.next() {
                processReply(reply)
            }
            // Bridge returned nil = shutdown
        }

        /// Process a registration reply.
        ///
        /// Wraps leaf errors from the poll thread in `Failure.failure(leaf)` to maintain
        /// typed error discipline. The poll thread produces `Result<Payload, IO.NonBlocking.Error>`
        /// (leaf errors only), and this method converts to `Result<Payload, Failure>`.
        private func processReply(_ reply: IO.NonBlocking.Registration.Reply) {
            guard let continuation = pendingReplies.removeValue(forKey: reply.id) else {
                // No pending continuation - reply was likely for a shutdown deregistration
                return
            }
            switch reply.result {
            case .success(let payload):
                continuation.resume(returning: .success(payload))
            case .failure(let leaf):
                // Wrap leaf error in lifecycle failure
                continuation.resume(returning: .failure(.failure(leaf)))
            }
        }

        /// Drain all cancelled waiters.
        ///
        /// Called after each event batch to ensure cancelled waiters are resumed
        /// promptly. The cancellation handler triggers a wakeup to ensure the
        /// actor touches this method even if no events are pending.
        private func drainCancelledWaiters() {
            for (key, waiter) in waiters where waiter.wasCancelled {
                waiters.removeValue(forKey: key)
                if let (continuation, _) = waiter.takeForResume() {
                    continuation.resume(returning: .failure(.cancelled))
                }
            }
        }

        private func processEvent(_ event: Event) {
            // For each interest bit in the event
            for interest in [Interest.read, .write, .priority] where event.interest.contains(interest) {
                let key = PermitKey(id: event.id, interest: interest)
                if let waiter = waiters.removeValue(forKey: key) {
                    // Drain the waiter using state machine
                    if let (continuation, wasCancelled) = waiter.takeForResume() {
                        if wasCancelled {
                            continuation.resume(returning: .failure(.cancelled))
                        } else {
                            // Resume with a single-interest event for deterministic semantics
                            let ready = Event(id: event.id, interest: interest, flags: event.flags)
                            continuation.resume(returning: .success(ready))
                        }
                    }
                } else {
                    // Store as permit
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

            // Drain all pending registration replies with lifecycle shutdown error
            // CRITICAL: Ensures no continuation leaks during shutdown
            // Uses proper lifecycle error (.shutdownInProgress), not a leaf sentinel
            for (_, continuation) in pendingReplies {
                continuation.resume(returning: .failure(.shutdownInProgress))
            }
            pendingReplies.removeAll()

            // Enqueue deregistrations for all remaining registrations (fire-and-forget)
            for id in registrations.keys {
                registrationQueue.enqueue(IO.NonBlocking.Registration.Request.deregister(id: id, replyID: nil))
            }
            registrations.removeAll()

            // Signal shutdown to bridges
            eventBridge.shutdown()
            replyBridge.shutdown()

            // Wait for poll thread to complete
            pollThreadHandle.join()

            state = .shutdown
        }
    }
}

// MARK: - Construction

extension IO.NonBlocking.Selector {
    /// Namespace for selector construction.
    public enum Make {
        /// Errors that can occur during selector construction.
        ///
        /// This is a construction-specific error type, separate from runtime
        /// I/O errors (`IO.NonBlocking.Error`) and lifecycle errors (`Failure`).
        public enum Error: Swift.Error, Sendable {
            /// Driver failed to create handle or wakeup channel.
            case driver(IO.NonBlocking.Error)

            /// Typed conversion helper for driver operations.
            ///
            /// Converts `throws(IO.NonBlocking.Error)` to `throws(Make.Error)`
            /// without existential widening or `as` casts in catch clauses.
            @inline(__always)
            static func driver<T: ~Copyable>(
                _ body: () throws(IO.NonBlocking.Error) -> T
            ) throws(IO.NonBlocking.Selector.Make.Error) -> T {
                do { return try body() }
                catch let e { throw .driver(e) }
            }
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
            public var token: Token<IO.NonBlocking.Armed>

            /// The event that triggered readiness.
            public let event: Event

            @usableFromInline
            package init(token: consuming Token<IO.NonBlocking.Armed>, event: Event) {
                self.token = token
                self.event = event
            }
        }

        // MARK: - Token-Preserving Outcome Types

        /// Namespace for arming from `Token<Registering>`.
        public enum Registering {
            /// Outcome of arming from a `Token<Registering>`.
            ///
            /// Uses an outcome enum instead of throwing because Swift's `Error` protocol
            /// requires `Copyable`, which is incompatible with move-only tokens.
            /// This enum makes token loss unrepresentable at the API boundary.
            public enum Outcome: ~Copyable, Sendable {
                /// Arming succeeded - returns the armed result with token and event.
                case armed(Result)
                /// Arming failed - returns the original token for restoration.
                case failed(token: Token<IO.NonBlocking.Registering>, failure: Failure)
            }
        }

        /// Namespace for arming from `Token<Armed>`.
        public enum Armed {
            /// Outcome of arming from a `Token<Armed>`.
            ///
            /// Uses an outcome enum instead of throwing because Swift's `Error` protocol
            /// requires `Copyable`, which is incompatible with move-only tokens.
            /// This enum makes token loss unrepresentable at the API boundary.
            public enum Outcome: ~Copyable, Sendable {
                /// Arming succeeded - returns the armed result with token and event.
                case armed(Result)
                /// Arming failed - returns the original token for restoration.
                case failed(token: Token<IO.NonBlocking.Armed>, failure: Failure)
            }
        }
    }
}
