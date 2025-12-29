//
//  IO.NonBlocking.Fake.swift
//  swift-io
//
//  Deterministic fake driver for testing non-blocking I/O invariants.
//

import Synchronization
@testable import IO_NonBlocking

// MARK: - Fake Driver

extension IO.NonBlocking {
    /// Deterministic fake driver for testing.
    ///
    /// The fake driver allows tests to:
    /// - Verify registration/modify/deregister contract
    /// - Inject events deterministically
    /// - Test permit consumption and exactly-once resume
    /// - Test shutdown rejection
    ///
    /// ## Thread Safety
    /// All operations are synchronized via a mutex. The controller
    /// can inject events from any thread.
    enum Fake {
        /// Creates a fake driver with the given controller.
        static func driver(controller: Controller) -> Driver {
            Driver(
                capabilities: Driver.Capabilities(
                    maxEvents: 64,
                    supportsEdgeTriggered: true,
                    isCompletionBased: false
                ),
                create: { () throws(IO.NonBlocking.Error) -> Driver.Handle in
                    controller.create()
                },
                register: { (handle: borrowing Driver.Handle, descriptor: Int32, interest: Interest) throws(IO.NonBlocking.Error) -> ID in
                    try controller.register(handle, descriptor: descriptor, interest: interest)
                },
                modify: { (handle: borrowing Driver.Handle, id: ID, interest: Interest) throws(IO.NonBlocking.Error) in
                    try controller.modify(handle, id: id, interest: interest)
                },
                deregister: { (handle: borrowing Driver.Handle, id: ID) throws(IO.NonBlocking.Error) in
                    try controller.deregister(handle, id: id)
                },
                poll: { (handle: borrowing Driver.Handle, deadline: Deadline?, buffer: inout [Event]) throws(IO.NonBlocking.Error) -> Int in
                    controller.poll(handle, deadline: deadline, into: &buffer)
                },
                close: { (handle: consuming Driver.Handle) in
                    controller.close(handle)
                },
                createWakeupChannel: { (handle: borrowing Driver.Handle) throws(IO.NonBlocking.Error) -> Wakeup.Channel in
                    controller.createWakeupChannel(handle)
                }
            )
        }
    }
}

// MARK: - Controller

extension IO.NonBlocking.Fake {
    /// Test controller for the fake driver.
    ///
    /// Provides methods to:
    /// - Inspect current registrations
    /// - Inject events for specific IDs
    /// - Trigger wakeups
    /// - Simulate shutdown
    final class Controller: @unchecked Sendable {
        private let state: Mutex<State>

        init() {
            self.state = Mutex(State())
        }

        // MARK: - State

        private struct State {
            var nextID: UInt64 = 1
            var nextHandleID: Int32 = 1
            var handles: [Int32: HandleState] = [:]
            var isShutdown: Bool = false
        }

        struct HandleState {
            var registrations: [IO.NonBlocking.ID: Registration] = [:]
            var pendingEvents: [IO.NonBlocking.Event] = []
            var wakeupPending: Bool = false
        }

        /// Registration entry tracking descriptor and interests.
        struct Registration: Sendable, Equatable {
            let descriptor: Int32
            var interest: IO.NonBlocking.Interest
        }

        // MARK: - Test Inspection API

        /// Returns all current registrations for a handle.
        func registrations(for handle: borrowing IO.NonBlocking.Driver.Handle) -> [IO.NonBlocking.ID: Registration] {
            state.withLock { $0.handles[handle.rawValue]?.registrations ?? [:] }
        }

        /// Returns a specific registration.
        func registration(for id: IO.NonBlocking.ID, handle: borrowing IO.NonBlocking.Driver.Handle) -> Registration? {
            state.withLock { $0.handles[handle.rawValue]?.registrations[id] }
        }

        /// Returns whether an ID is currently registered.
        func isRegistered(_ id: IO.NonBlocking.ID, handle: borrowing IO.NonBlocking.Driver.Handle) -> Bool {
            registration(for: id, handle: handle) != nil
        }

        // MARK: - Event Injection API

        /// Pushes an event to be returned by the next poll.
        func pushEvent(_ event: IO.NonBlocking.Event, handle: borrowing IO.NonBlocking.Driver.Handle) {
            state.withLock { state in
                state.handles[handle.rawValue]?.pendingEvents.append(event)
            }
        }

        /// Pushes multiple events.
        func pushEvents(_ events: [IO.NonBlocking.Event], handle: borrowing IO.NonBlocking.Driver.Handle) {
            state.withLock { state in
                state.handles[handle.rawValue]?.pendingEvents.append(contentsOf: events)
            }
        }

        /// Triggers a wakeup (causes poll to return immediately with 0 events).
        func triggerWakeup(handle: borrowing IO.NonBlocking.Driver.Handle) {
            state.withLock { state in
                state.handles[handle.rawValue]?.wakeupPending = true
            }
        }

        /// Simulates shutdown (all subsequent operations fail).
        func simulateShutdown() {
            state.withLock { $0.isShutdown = true }
        }

        // MARK: - Driver Operations

        func create() -> IO.NonBlocking.Driver.Handle {
            state.withLock { state in
                let id = state.nextHandleID
                state.nextHandleID += 1
                state.handles[id] = HandleState()
                return IO.NonBlocking.Driver.Handle(rawValue: id)
            }
        }

        func register(
            _ handle: borrowing IO.NonBlocking.Driver.Handle,
            descriptor: Int32,
            interest: IO.NonBlocking.Interest
        ) throws(IO.NonBlocking.Error) -> IO.NonBlocking.ID {
            let handleID = handle.rawValue
            var result: Result<IO.NonBlocking.ID, IO.NonBlocking.Error>!
            state.withLock { state in
                guard !state.isShutdown else {
                    result = .failure(.invalidDescriptor)
                    return
                }
                guard state.handles[handleID] != nil else {
                    result = .failure(.invalidDescriptor)
                    return
                }

                let id = IO.NonBlocking.ID(raw: state.nextID)
                state.nextID += 1
                state.handles[handleID]?.registrations[id] = Registration(
                    descriptor: descriptor,
                    interest: interest
                )
                result = .success(id)
            }
            return try result.get()
        }

        func modify(
            _ handle: borrowing IO.NonBlocking.Driver.Handle,
            id: IO.NonBlocking.ID,
            interest: IO.NonBlocking.Interest
        ) throws(IO.NonBlocking.Error) {
            let handleID = handle.rawValue
            var error: IO.NonBlocking.Error?
            state.withLock { state in
                guard !state.isShutdown else {
                    error = .invalidDescriptor
                    return
                }
                guard state.handles[handleID]?.registrations[id] != nil else {
                    error = .notRegistered
                    return
                }
                state.handles[handleID]?.registrations[id]?.interest = interest
            }
            if let error { throw error }
        }

        func deregister(
            _ handle: borrowing IO.NonBlocking.Driver.Handle,
            id: IO.NonBlocking.ID
        ) throws(IO.NonBlocking.Error) {
            let handleID = handle.rawValue
            var error: IO.NonBlocking.Error?
            state.withLock { state in
                guard !state.isShutdown else {
                    error = .invalidDescriptor
                    return
                }
                // Idempotent: succeed silently if not registered
                _ = state.handles[handleID]?.registrations.removeValue(forKey: id)
            }
            if let error { throw error }
        }

        func poll(
            _ handle: borrowing IO.NonBlocking.Driver.Handle,
            deadline: IO.NonBlocking.Deadline?,
            into buffer: inout [IO.NonBlocking.Event]
        ) -> Int {
            let handleID = handle.rawValue
            return state.withLock { state in
                guard let handleState = state.handles[handleID] else {
                    return 0
                }

                // Check wakeup
                if state.handles[handleID]?.wakeupPending == true {
                    state.handles[handleID]?.wakeupPending = false
                    return 0
                }

                // Return pending events
                let events = state.handles[handleID]?.pendingEvents ?? []
                state.handles[handleID]?.pendingEvents = []

                // Filter out events for deregistered IDs
                let validEvents = events.filter { event in
                    handleState.registrations[event.id] != nil
                }

                let count = min(validEvents.count, buffer.count)
                for i in 0..<count {
                    buffer[i] = validEvents[i]
                }
                return count
            }
        }

        func close(_ handle: consuming IO.NonBlocking.Driver.Handle) {
            _ = state.withLock { state in
                state.handles.removeValue(forKey: handle.rawValue)
            }
        }

        func createWakeupChannel(_ handle: borrowing IO.NonBlocking.Driver.Handle) -> IO.NonBlocking.Wakeup.Channel {
            let handleID = handle.rawValue
            return IO.NonBlocking.Wakeup.Channel { [weak self] in
                self?.state.withLock { state in
                    state.handles[handleID]?.wakeupPending = true
                }
            }
        }
    }
}
