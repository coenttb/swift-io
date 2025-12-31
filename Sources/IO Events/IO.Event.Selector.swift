//
//  IO.Event.Selector.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 28/12/2025.
//

@_exported public import IO_Events_Driver


extension IO.Event {
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
    /// let selector = try IO.Event.Selector.make()
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
        private let eventBridge: IO.Event.Bridge

        /// Bridge for receiving registration replies from poll thread.
        private let replyBridge: IO.Event.Registration.Reply.Bridge

        /// Queue for sending requests to poll thread.
        private let registrationQueue: IO.Event.Registration.Queue

        /// Flag for signaling shutdown to poll thread.
        private let shutdownFlag: PollLoop.Shutdown.Flag

        /// Handle to the poll thread (consumed on shutdown).
        private var pollThreadHandle: IO.Thread.Handle?

        /// Registration table.
        private var registrations: [ID: Registration] = [:]

        /// Waiter storage keyed by (ID, Interest).
        private var waiters: [PermitKey: Waiter] = [:]

        /// Permit storage keyed by (ID, Interest).
        private var permits: [PermitKey: IO.Event.Flags] = [:]

        /// Current lifecycle state.
        private var state: LifecycleState = .running

        // MARK: - Deadline State

        /// Atomic next poll deadline shared with poll thread.
        private let nextDeadline: PollLoop.NextDeadline

        /// Min-heap of deadline entries for scheduling.
        private var deadlineHeap: DeadlineScheduling.MinHeap = .init()

        /// Generation counter per key for stale entry detection.
        ///
        /// When a waiter completes (success, cancelled, timeout, deregistered),
        /// its generation is bumped. Heap entries with stale generations are skipped.
        private var deadlineGeneration: [PermitKey: UInt64] = [:]

        /// Pending registration reply continuations keyed by ReplyID.
        ///
        /// Selector owns these continuations and resumes them when replies arrive.
        /// This enforces the single resumption funnel invariant.
        ///
        /// Uses typed `Failure` (not untyped `Error`) to maintain lifecycle discipline:
        /// - Poll thread produces `Result<Payload, IO.Event.Error>` (leaf errors)
        /// - Selector wraps leaf errors in `.failure(.failure(leaf))`
        /// - Shutdown drains with `.failure(.shutdownInProgress)` (lifecycle error)
        private var pendingReplies: [IO.Event.Registration.ReplyID: CheckedContinuation<Result<IO.Event.Registration.Payload, Failure>, Never>] = [:]

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
            eventBridge: IO.Event.Bridge,
            replyBridge: IO.Event.Registration.Reply.Bridge,
            registrationQueue: IO.Event.Registration.Queue,
            shutdownFlag: PollLoop.Shutdown.Flag,
            nextDeadline: PollLoop.NextDeadline,
            pollThreadHandle: consuming IO.Thread.Handle
        ) {
            self.driver = driver
            self.executor = executor
            self.wakeupChannel = wakeupChannel
            self.eventBridge = eventBridge
            self.replyBridge = replyBridge
            self.registrationQueue = registrationQueue
            self.shutdownFlag = shutdownFlag
            self.nextDeadline = nextDeadline
            self.pollThreadHandle = consume pollThreadHandle
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
                () throws(IO.Event.Error) -> Driver.Handle in try driver.create()
            }
            let wakeupChannel = try Make.Error.driver {
                () throws(IO.Event.Error) -> Wakeup.Channel in try driver.createWakeupChannel(handle)
            }

            // Create communication primitives
            let eventBridge = IO.Event.Bridge()
            let replyBridge = IO.Event.Registration.Reply.Bridge()
            let registrationQueue = IO.Event.Registration.Queue()
            let shutdownFlag = PollLoop.Shutdown.Flag()
            let nextDeadline = PollLoop.NextDeadline()

            // Create context for poll thread
            let context = PollLoop.Context(
                driver: driver,
                handle: handle,
                eventBridge: eventBridge,
                replyBridge: replyBridge,
                registrationQueue: registrationQueue,
                shutdownFlag: shutdownFlag,
                nextDeadline: nextDeadline
            )

            // Start poll thread with context
            // Uses trap because thread spawn failure is unrecoverable for the selector runtime
            let pollThreadHandle = IO.Thread.trap(context) { context in
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
                nextDeadline: nextDeadline,
                pollThreadHandle: pollThreadHandle
            )

            // Start event and reply loops - enforced by construction
            // await is for actor isolation, start() itself is synchronous (spawns Tasks)
            await selector.start()

            return selector
        }

        /// Creates a new selector with the platform-default driver.
        ///
        /// Convenience factory that uses `Driver.platform` for the current OS.
        ///
        /// - Parameter executor: The executor to pin the actor to.
        /// - Returns: A new, running selector.
        /// - Throws: `Make.Error` if construction fails.
        public static func make(
            executor: IO.Executor.Thread
        ) async throws(Make.Error) -> Selector {
            try await make(driver: .platform, executor: executor)
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
            let replyID = IO.Event.Registration.ReplyID(raw: nextReplyID)
            nextReplyID &+= 1  // Wrapping add OK

            // Store continuation and enqueue request
            let result: Result<IO.Event.Registration.Payload, Failure> = await withCheckedContinuation { continuation in
                pendingReplies[replyID] = continuation
                let request = IO.Event.Registration.Request.register(
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
        ///   - deadline: Optional deadline for the arm wait.
        /// - Returns: `.armed(result)` on success, `.failed(token:failure:)` on failure.
        public func armPreservingToken(
            _ token: consuming Token<Registering>,
            interest: Interest,
            deadline: Deadline? = nil
        ) async -> Arm.Registering.Outcome {
            do {
                let result = try await arm(id: token.id, interest: interest, deadline: deadline)
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
        ///   - deadline: Optional deadline for the arm wait.
        /// - Returns: `.armed(result)` on success, `.failed(token:failure:)` on failure.
        public func armPreservingToken(
            _ token: consuming Token<Armed>,
            interest: Interest,
            deadline: Deadline? = nil
        ) async -> Arm.Armed.Outcome {
            do {
                let result = try await arm(id: token.id, interest: interest, deadline: deadline)
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
        ///   - deadline: Optional deadline for the arm wait. If the deadline expires
        ///     before an event arrives, throws `.timeout`.
        /// - Returns: An armed token and the event when ready.
        /// - Throws: `Failure` on shutdown, cancellation, or timeout. Token is lost on failure.
        public func arm(
            _ token: consuming Token<Registering>,
            interest: Interest,
            deadline: Deadline? = nil
        ) async throws(Failure) -> Arm.Result {
            switch await armPreservingToken(consume token, interest: interest, deadline: deadline) {
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
        ///   - deadline: Optional deadline for the arm wait. If the deadline expires
        ///     before an event arrives, throws `.timeout`.
        /// - Returns: An armed token and the event when ready.
        /// - Throws: `Failure` on shutdown, cancellation, or timeout. Token is lost on failure.
        public func arm(
            _ token: consuming Token<Armed>,
            interest: Interest,
            deadline: Deadline? = nil
        ) async throws(Failure) -> Arm.Result {
            switch await armPreservingToken(consume token, interest: interest, deadline: deadline) {
            case .armed(let result):
                return result
            case .failed(_, let failure):
                throw failure
            }
        }

        // MARK: - Two-Phase Arm (Batch Support)

        /// Begin an arm operation, consuming the token.
        ///
        /// This is phase 1 of the two-phase arm pattern. It:
        /// 1. Consumes the token (capability transferred)
        /// 2. Checks for existing permit (immediate readiness)
        /// 3. If no permit: creates unarmed waiter, arms kernel, returns handle
        ///
        /// **No deadline is scheduled here.** Deadlines are associated with the
        /// actual suspension in `awaitArm`, not with the IO operation setup.
        ///
        /// - Parameters:
        ///   - token: The registering token (consumed).
        ///   - interest: The interest to wait for.
        /// - Returns: `.ready(IO.Event)` if permit existed, `.pending(Handle)` otherwise.
        /// - Throws: If shutdown is in progress.
        public func beginArmDiscardingToken(
            _ token: consuming Token<Registering>,
            interest: Interest
        ) throws(Failure) -> Arm.Begin {
            guard state == .running else {
                throw .shutdownInProgress
            }

            let id = token.id
            _ = consume token  // Token consumed

            let key = PermitKey(id: id, interest: interest)

            // Check for existing permit (event already arrived)
            if let flags = permits.removeValue(forKey: key) {
                // Consume permit and return immediate readiness.
                // No kernel mutation here - if caller wants to wait again,
                // they call beginArmDiscardingToken with a fresh token.
                let event = IO.Event(id: id, interest: interest, flags: flags)
                return .ready(event)
            }

            // No permit - create unarmed waiter
            let waiter = Waiter(id: id)
            waiters[key] = waiter

            // Arm the kernel filter
            registrationQueue.enqueue(.arm(id: id, interest: interest))
            wakeupChannel.wake()

            // Return handle with current generation
            let generation = deadlineGeneration[key, default: 0]
            let handle = Arm.Handle(id: id, interest: interest, generation: generation)
            return .pending(handle)
        }

        /// Await completion of a pending arm operation.
        ///
        /// This is phase 2 of the two-phase arm pattern. It:
        /// 1. Validates the waiter exists and generation matches
        /// 2. Installs continuation on the waiter and suspends
        /// 3. Schedules the deadline (if provided) only after arming
        ///
        /// **Note:** This method does NOT check permits. Permits are consumed
        /// exclusively in phase 1 (`beginArmDiscardingToken`). If an event
        /// arrived between phase 1 and phase 2, `processEvent` converts it
        /// to a permit and removes the unarmed waiter - this method then
        /// fails with `.cancelled` due to missing waiter.
        ///
        /// - Parameters:
        ///   - handle: The handle from `beginArmDiscardingToken` (pending case only).
        ///   - deadline: Optional deadline for this wait.
        /// - Returns: The outcome (armed with event, or failed).
        public func awaitArm(
            _ handle: Arm.Handle,
            deadline: Deadline? = nil
        ) async -> Arm.Outcome {
            let key = handle.key

            // Validate waiter exists
            guard let waiter = waiters[key] else {
                // Waiter was removed (event arrived and converted to permit,
                // deregistered, shutdown, etc.)
                return .failed(.cancelled)
            }

            // Verify generation to detect stale handles
            let currentGen = deadlineGeneration[key, default: 0]
            if currentGen != handle.generation {
                // Stale handle - waiter was already completed and a new one started
                return .failed(.cancelled)
            }

            // Install continuation and suspend
            let wakeup = wakeupChannel

            let result: Result<IO.Event, Failure> = await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    let armed = waiter.arm(continuation: continuation)
                    precondition(armed, "Waiter must arm exactly once")

                    // Schedule deadline only after arming (deadline is for suspension)
                    if let deadline = deadline {
                        scheduleDeadline(deadline, for: key)
                    }
                }
            } onCancel: {
                waiter.cancel()
                wakeup.wake()
            }

            switch result {
            case .success(let event):
                return .armed(event)
            case .failure(let failure):
                return .failed(failure)
            }
        }

        /// Arm two registrations concurrently, returning simplified outcomes.
        ///
        /// This method uses the two-phase arm pattern internally:
        /// 1. `beginArmDiscardingToken` for both (consumes tokens, checks permits)
        /// 2. `async let` to await any pending handles concurrently
        ///
        /// Both operations are initiated before either suspends, enabling
        /// multiple pending deadlines to be tested simultaneously.
        ///
        /// - Parameters:
        ///   - request1: First arm request (consumed).
        ///   - request2: Second arm request (consumed).
        /// - Returns: Tuple of outcomes for each request.
        public func armTwo(
            _ request1: consuming Arm.Request,
            _ request2: consuming Arm.Request
        ) async -> (Arm.Outcome, Arm.Outcome) {
            // Phase 1: Begin both arms (synchronous, consumes tokens)
            let begin1: Arm.Begin
            let begin2: Arm.Begin

            do {
                begin1 = try beginArmDiscardingToken(
                    consume request1.token,
                    interest: request1.interest
                )
            } catch {
                // First begin failed - still need to handle second token
                do {
                    begin2 = try beginArmDiscardingToken(
                        consume request2.token,
                        interest: request2.interest
                    )
                    // Second succeeded but first failed
                    let outcome2: Arm.Outcome
                    switch begin2 {
                    case .ready(let event):
                        outcome2 = .armed(event)
                    case .pending(let handle):
                        outcome2 = await awaitArm(handle, deadline: request2.deadline)
                    }
                    return (.failed(error), outcome2)
                } catch let error2 {
                    return (.failed(error), .failed(error2))
                }
            }

            do {
                begin2 = try beginArmDiscardingToken(
                    consume request2.token,
                    interest: request2.interest
                )
            } catch {
                // Second begin failed - first already started
                let outcome1: Arm.Outcome
                switch begin1 {
                case .ready(let event):
                    outcome1 = .armed(event)
                case .pending(let handle):
                    outcome1 = await awaitArm(handle, deadline: request1.deadline)
                }
                return (outcome1, .failed(error))
            }

            // Extract deadlines before async let
            let deadline1 = request1.deadline
            let deadline2 = request2.deadline

            // Phase 2: Handle both results
            // If both are ready, return immediately
            // If both are pending, await concurrently
            // If mixed, await the pending one
            switch (begin1, begin2) {
            case (.ready(let event1), .ready(let event2)):
                return (.armed(event1), .armed(event2))

            case (.ready(let event1), .pending(let handle2)):
                let outcome2 = await awaitArm(handle2, deadline: deadline2)
                return (.armed(event1), outcome2)

            case (.pending(let handle1), .ready(let event2)):
                let outcome1 = await awaitArm(handle1, deadline: deadline1)
                return (outcome1, .armed(event2))

            case (.pending(let handle1), .pending(let handle2)):
                // Both pending - await concurrently
                async let result1 = awaitArm(handle1, deadline: deadline1)
                async let result2 = awaitArm(handle2, deadline: deadline2)
                return await (result1, result2)
            }
        }

        /// Private implementation of interest-specific arming.
        ///
        /// - Parameters:
        ///   - id: The registration ID.
        ///   - interest: The interest to wait for.
        ///   - deadline: Optional deadline for the arm operation.
        /// - Returns: An armed token and the event when ready.
        /// - Throws: If shutdown, cancelled, or timed out.
        private func arm(
            id: ID,
            interest: Interest,
            deadline: Deadline? = nil
        ) async throws(Failure) -> Arm.Result {
            guard state == .running else {
                throw .shutdownInProgress
            }

            let key = PermitKey(id: id, interest: interest)

            // Check for existing permit for this specific interest.
            // A permit means an edge already occurred before we armed;
            // consume it without re-arming the kernel.
            if let flags = permits.removeValue(forKey: key) {
                // Re-arm the kernel for future edges before returning.
                // This ensures the filter is ready for the next arm() call.
                registrationQueue.enqueue(.arm(id: id, interest: interest))
                wakeupChannel.wake()

                let event = IO.Event(id: id, interest: interest, flags: flags)
                return Arm.Result(token: Token(id: id), event: event)
            }

            // No permit - arm the kernel and create waiter.
            //
            // CRITICAL: Send the arm request BEFORE parking the waiter.
            // With EV_DISPATCH (one-shot), the filter is disabled after
            // delivering an event. We must enable it to receive the next edge.
            registrationQueue.enqueue(.arm(id: id, interest: interest))
            wakeupChannel.wake()

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

            let result: Result<IO.Event, Failure> = await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    let armed = waiter.arm(continuation: continuation)
                    precondition(armed, "Waiter must arm exactly once before insertion")
                    waiters[key] = waiter

                    // Schedule deadline if provided
                    if let deadline = deadline {
                        scheduleDeadline(deadline, for: key)
                    }
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

        /// Schedule a deadline for a waiter.
        ///
        /// Adds an entry to the deadline heap and updates the poll deadline atomic.
        private func scheduleDeadline(_ deadline: Deadline, for key: PermitKey) {
            let gen = deadlineGeneration[key, default: 0] + 1
            deadlineGeneration[key] = gen

            let entry = DeadlineScheduling.Entry(
                deadline: deadline.nanoseconds,
                key: key,
                generation: gen
            )
            deadlineHeap.push(entry)
            updateNextPollDeadline()
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
                if let waiter = waiters.removeValue(forKey: key) {
                    // Bump generation to invalidate any stale heap entries
                    bumpGeneration(for: key)
                    if let (continuation, _) = waiter.takeForResume() {
                        continuation.resume(returning: .failure(.failure(.deregistered)))
                    }
                }
            }

            // Remove permits and deadline generation for this ID
            for interest in [Interest.read, .write, .priority] {
                let key = PermitKey(id: id, interest: interest)
                permits.removeValue(forKey: key)
                deadlineGeneration.removeValue(forKey: key)
            }

            // Generate reply ID for matching request to reply
            let replyID = IO.Event.Registration.ReplyID(raw: nextReplyID)
            nextReplyID &+= 1

            // Store continuation and enqueue request
            let result: Result<IO.Event.Registration.Payload, Failure> = await withCheckedContinuation { continuation in
                pendingReplies[replyID] = continuation
                let request = IO.Event.Registration.Request.deregister(
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
        ///
        /// Processing order per batch:
        /// 1. Process events (resuming successful waiters)
        /// 2. Drain cancelled waiters
        /// 3. Drain expired deadlines
        ///
        /// This order ensures "event wins over timeout" semantics when both
        /// occur in the same selector turn.
        public func runEventLoop() async {
            while let batch = await eventBridge.next() {
                for event in batch {
                    processEvent(event)
                }
                // Drain any waiters that were cancelled during this touch
                drainCancelledWaiters()
                // Drain expired deadlines (get time once per turn)
                let now = Deadline.now.nanoseconds
                drainExpiredDeadlines(now: now)
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
        /// typed error discipline. The poll thread produces `Result<Payload, IO.Event.Error>`
        /// (leaf errors only), and this method converts to `Result<Payload, Failure>`.
        private func processReply(_ reply: IO.Event.Registration.Reply) {
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
                bumpGeneration(for: key)
                if let (continuation, _) = waiter.takeForResume() {
                    continuation.resume(returning: .failure(.cancelled))
                }
            }
            updateNextPollDeadline()
        }

        /// Drain all expired deadlines.
        ///
        /// Called after each event batch to resume waiters whose deadlines have passed.
        /// Stale heap entries (where generation doesn't match) are silently skipped.
        ///
        /// - Parameter now: The current monotonic time in nanoseconds.
        private func drainExpiredDeadlines(now: UInt64) {
            while let entry = deadlineHeap.peek() {
                // Not expired yet - stop
                if entry.deadline > now {
                    break
                }

                // Pop and check validity
                _ = deadlineHeap.pop()

                // Skip stale entries (generation mismatch)
                guard let currentGen = deadlineGeneration[entry.key],
                      currentGen == entry.generation else {
                    continue
                }

                // Check if waiter exists
                guard let waiter = waiters[entry.key] else {
                    continue
                }

                // Two-phase support:
                // If waiter exists but is not armed (continuation not installed),
                // skip it. The deadline applies to the actual suspension, not to
                // the IO operation. An unarmed waiter means awaitArm hasn't been
                // called yet, so there's no "wait" to timeout.
                if !waiter.isArmed {
                    continue
                }

                // Armed waiter: remove, bump generation, and resume with timeout
                _ = waiters.removeValue(forKey: entry.key)
                bumpGeneration(for: entry.key)

                if let (continuation, wasCancelled) = waiter.takeForResume() {
                    if wasCancelled {
                        // Cancellation already happened - honour it
                        continuation.resume(returning: .failure(.cancelled))
                    } else {
                        continuation.resume(returning: .failure(.timeout))
                    }
                }
            }
            updateNextPollDeadline()
        }

        /// Bump the generation for a key, invalidating any stale heap entries.
        private func bumpGeneration(for key: PermitKey) {
            deadlineGeneration[key, default: 0] += 1
        }

        /// Update the shared atomic with the next poll deadline.
        ///
        /// Pops stale entries from the heap until a valid one is found,
        /// then publishes it to the poll thread.
        private func updateNextPollDeadline() {
            // Pop stale entries
            while let entry = deadlineHeap.peek() {
                guard let currentGen = deadlineGeneration[entry.key],
                      currentGen == entry.generation,
                      waiters[entry.key] != nil else {
                    // Stale - remove
                    _ = deadlineHeap.pop()
                    continue
                }
                break
            }

            // Publish earliest valid deadline (or max if none)
            if let entry = deadlineHeap.peek() {
                let previous = nextDeadline.nanoseconds
                nextDeadline.store(entry.deadline)
                // Wake poll thread if deadline moved earlier
                if entry.deadline < previous {
                    wakeupChannel.wake()
                }
            } else {
                nextDeadline.store(.max)
            }
        }

        private func processEvent(_ event: IO.Event) {
            // For each interest bit in the event
            for interest in [Interest.read, .write, .priority] where event.interest.contains(interest) {
                let key = PermitKey(id: event.id, interest: interest)

                if let waiter = waiters.removeValue(forKey: key) {
                    // Always bump generation when removing a waiter for this key.
                    // This invalidates any stale heap entries for deadlines.
                    bumpGeneration(for: key)

                    // Two-phase support:
                    // If the waiter exists but is not armed yet (continuation not installed),
                    // convert readiness into a permit. The later awaitArm() will observe
                    // the permit and complete immediately.
                    if !waiter.isArmed {
                        permits[key] = event.flags
                        continue
                    }

                    // Armed waiter: drain via the state machine.
                    if let (continuation, wasCancelled) = waiter.takeForResume() {
                        if wasCancelled {
                            continuation.resume(returning: .failure(.cancelled))
                        } else {
                            // Resume with a single-interest event for deterministic semantics
                            let ready = IO.Event(id: event.id, interest: interest, flags: event.flags)
                            continuation.resume(returning: .success(ready))
                        }
                    } else {
                        // Defensive fallback:
                        // If we removed it but couldn't take a continuation (already drained),
                        // preserve readiness for the next arm.
                        permits[key] = event.flags
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

            // Clear deadline state (no need to bump generations - heap is being dropped)
            deadlineHeap = .init()
            deadlineGeneration.removeAll()
            nextDeadline.store(.max)

            // Drain all pending registration replies with lifecycle shutdown error
            // CRITICAL: Ensures no continuation leaks during shutdown
            // Uses proper lifecycle error (.shutdownInProgress), not a leaf sentinel
            for (_, continuation) in pendingReplies {
                continuation.resume(returning: .failure(.shutdownInProgress))
            }
            pendingReplies.removeAll()

            // Enqueue deregistrations for all remaining registrations (fire-and-forget)
            for id in registrations.keys {
                registrationQueue.enqueue(IO.Event.Registration.Request.deregister(id: id, replyID: nil))
            }
            registrations.removeAll()

            // Signal shutdown to bridges
            eventBridge.shutdown()
            replyBridge.shutdown()

            // Wait for poll thread to complete (consume the handle)
            pollThreadHandle.take()?.join()

            state = .shutdown
        }
    }
}

// MARK: - Construction

extension IO.Event.Selector {
    /// Namespace for selector construction.
    public enum Make {
        /// Errors that can occur during selector construction.
        ///
        /// This is a construction-specific error type, separate from runtime
        /// I/O errors (`IO.Event.Error`) and lifecycle errors (`Failure`).
        public enum Error: Swift.Error, Sendable {
            /// Driver failed to create handle or wakeup channel.
            case driver(IO.Event.Error)

            /// Typed conversion helper for driver operations.
            ///
            /// Converts `throws(IO.Event.Error)` to `throws(Make.Error)`
            /// without existential widening or `as` casts in catch clauses.
            @inline(__always)
            static func driver<T: ~Copyable>(
                _ body: () throws(IO.Event.Error) -> T
            ) throws(IO.Event.Selector.Make.Error) -> T {
                do { return try body() }
                catch let e { throw .driver(e) }
            }
        }
    }
}

// MARK: - Supporting Types

extension IO.Event.Selector {
    /// Lifecycle state of the selector.
    enum LifecycleState {
        case running
        case shuttingDown
        case shutdown
    }

    /// A registered descriptor.
    struct Registration {
        let descriptor: Int32
        var interest: IO.Event.Interest
    }

    /// Key for permit storage.
    struct PermitKey: Hashable {
        let id: IO.Event.ID
        let interest: IO.Event.Interest
    }
}

// MARK: - Result Types

extension IO.Event {
    /// Namespace for registration-related types.
    public enum Register {
        /// Result of registering a descriptor.
        ///
        /// Contains the registration ID and a token for arming.
        /// This struct is ~Copyable because it contains a move-only Token.
        @frozen
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
        @frozen
        public struct Result: ~Copyable, Sendable {
            /// Token for modifying, deregistering, or cancelling.
            public var token: Token<IO.Event.Armed>

            /// The event that triggered readiness.
            public let event: IO.Event

            @usableFromInline
            package init(token: consuming Token<IO.Event.Armed>, event: IO.Event) {
                self.token = token
                self.event = event
            }
        }

        // MARK: - Two-Phase Arm Types

        /// Handle for a pending arm operation.
        ///
        /// Returned by `beginArmDiscardingToken` and consumed by `awaitArm`.
        /// This is `Copyable` (unlike tokens) so it can be captured in `async let`.
        ///
        /// The handle includes a generation number to detect stale completions.
        /// If the underlying waiter is removed (event, deregister, shutdown) before
        /// `awaitArm` is called, the generation mismatch causes immediate failure.
        @frozen
        public struct Handle: Sendable, Hashable {
            /// The registration ID.
            public let id: ID

            /// The interest this handle is waiting for.
            public let interest: Interest

            /// Generation at the time of handle creation.
            ///
            /// Used to detect if the waiter was already consumed by an event
            /// or invalidated by deregistration before `awaitArm` was called.
            public let generation: UInt64

            /// Internal key for permit/waiter lookup.
            var key: IO.Event.Selector.PermitKey {
                IO.Event.Selector.PermitKey(id: id, interest: interest)
            }
        }

        /// Result of beginning an arm operation.
        ///
        /// Phase 1 (`beginArmDiscardingToken`) returns either:
        /// - `.ready(IO.Event)`: A permit existed, readiness is immediate
        /// - `.pending(Handle)`: No permit, use handle with `awaitArm`
        ///
        /// ## Single-Consumer Semantics
        ///
        /// **Permits are consumed exactly once in phase 1.** The `.ready` case
        /// means the permit was consumed; `awaitArm` does NOT check permits.
        /// This ensures clean phase separation and prevents double-consumption.
        ///
        /// If an event arrives between phase 1 (`.pending`) and phase 2 (`awaitArm`),
        /// `processEvent` converts the readiness to a permit and removes the unarmed
        /// waiter. The subsequent `awaitArm` fails with `.cancelled` due to the
        /// missing waiter - the permit is available for a future `beginArmDiscardingToken`.
        @frozen
        public enum Begin: Sendable {
            /// Readiness was already available (permit consumed).
            /// No need to call `awaitArm`.
            case ready(IO.Event)

            /// No readiness yet. Use the handle with `awaitArm` to suspend.
            case pending(Handle)
        }

        /// Simplified outcome for batch operations.
        ///
        /// Unlike `Arm.Registering.Outcome`, this is `Copyable` because it doesn't
        /// return tokens. Use when you don't need tokens back (e.g., testing timeouts).
        @frozen
        public enum Outcome: Sendable {
            /// Arming succeeded - includes the event that triggered it.
            case armed(IO.Event)
            /// Arming failed - includes the failure reason.
            case failed(Failure)
        }

        /// A request to arm a registration with optional deadline.
        ///
        /// Used with `armTwo` and similar batch methods.
        /// This enables concurrent deadline testing and efficient multi-connection setup.
        @frozen
        public struct Request: ~Copyable, Sendable {
            /// The token to arm (consumed).
            public var token: Token<IO.Event.Registering>

            /// The interest to wait for.
            public let interest: Interest

            /// Optional deadline for this arm operation.
            public let deadline: Deadline?

            /// Creates an arm request.
            public init(
                token: consuming Token<IO.Event.Registering>,
                interest: Interest,
                deadline: Deadline? = nil
            ) {
                self.token = token
                self.interest = interest
                self.deadline = deadline
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
                case failed(token: Token<IO.Event.Registering>, failure: Failure)
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
                case failed(token: Token<IO.Event.Armed>, failure: Failure)
            }
        }
    }
}
