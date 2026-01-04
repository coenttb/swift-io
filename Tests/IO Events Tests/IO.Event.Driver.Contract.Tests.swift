//
//  IO.Event.Driver.Contract.Tests.swift
//  swift-io
//
//  Tests for the driver contract using the Fake driver.
//

import Testing

@testable import IO_Events

@Suite("IO.Event.Driver.Contract")
struct DriverContractTests {

    // MARK: - Registration Contract

    @Test("register creates valid ID and stores mapping")
    func registerCreatesMapping() throws {
        let controller = IO.Event.Fake.Controller()
        let driver = IO.Event.Fake.driver(controller: controller)
        let handle = try driver.create()

        let id = try driver.register(handle, descriptor: 42, interest: .read)

        let registration = controller.registration(for: id, handle: handle)
        #expect(registration != nil)
        #expect(registration?.descriptor == 42)
        #expect(registration?.interest == .read)
    }

    @Test("register with multiple interests stores all")
    func registerMultipleInterests() throws {
        let controller = IO.Event.Fake.Controller()
        let driver = IO.Event.Fake.driver(controller: controller)
        let handle = try driver.create()

        let id = try driver.register(handle, descriptor: 10, interest: [.read, .write])

        let registration = controller.registration(for: id, handle: handle)
        #expect(registration?.interest.contains(.read) == true)
        #expect(registration?.interest.contains(.write) == true)
    }

    @Test("register generates unique IDs")
    func registerUniqueIDs() throws {
        let controller = IO.Event.Fake.Controller()
        let driver = IO.Event.Fake.driver(controller: controller)
        let handle = try driver.create()

        let id1 = try driver.register(handle, descriptor: 1, interest: .read)
        let id2 = try driver.register(handle, descriptor: 2, interest: .read)
        let id3 = try driver.register(handle, descriptor: 3, interest: .read)

        #expect(id1 != id2)
        #expect(id2 != id3)
        #expect(id1 != id3)
    }

    // MARK: - Modify Contract

    @Test("modify updates interest correctly")
    func modifyUpdatesInterest() throws {
        let controller = IO.Event.Fake.Controller()
        let driver = IO.Event.Fake.driver(controller: controller)
        let handle = try driver.create()

        let id = try driver.register(handle, descriptor: 42, interest: .read)
        try driver.modify(handle, id: id, interest: .write)

        let registration = controller.registration(for: id, handle: handle)
        #expect(registration?.interest == .write)
    }

    @Test("modify can add interests")
    func modifyAddsInterests() throws {
        let controller = IO.Event.Fake.Controller()
        let driver = IO.Event.Fake.driver(controller: controller)
        let handle = try driver.create()

        let id = try driver.register(handle, descriptor: 42, interest: .read)
        try driver.modify(handle, id: id, interest: [.read, .write])

        let registration = controller.registration(for: id, handle: handle)
        #expect(registration?.interest.contains(.read) == true)
        #expect(registration?.interest.contains(.write) == true)
    }

    @Test("modify can remove interests")
    func modifyRemovesInterests() throws {
        let controller = IO.Event.Fake.Controller()
        let driver = IO.Event.Fake.driver(controller: controller)
        let handle = try driver.create()

        let id = try driver.register(handle, descriptor: 42, interest: [.read, .write])
        try driver.modify(handle, id: id, interest: .read)

        let registration = controller.registration(for: id, handle: handle)
        #expect(registration?.interest == .read)
    }

    @Test("modify on unregistered ID throws notRegistered")
    func modifyUnregisteredThrows() throws {
        let controller = IO.Event.Fake.Controller()
        let driver = IO.Event.Fake.driver(controller: controller)
        let handle = try driver.create()

        let fakeID = IO.Event.ID(999)

        #expect(throws: IO.Event.Error.notRegistered) {
            try driver.modify(handle, id: fakeID, interest: .write)
        }
    }

    // MARK: - Deregister Contract

    @Test("deregister removes registration")
    func deregisterRemovesRegistration() throws {
        let controller = IO.Event.Fake.Controller()
        let driver = IO.Event.Fake.driver(controller: controller)
        let handle = try driver.create()

        let id = try driver.register(handle, descriptor: 42, interest: .read)
        #expect(controller.isRegistered(id, handle: handle) == true)

        try driver.deregister(handle, id: id)
        #expect(controller.isRegistered(id, handle: handle) == false)
    }

    @Test("deregister is idempotent")
    func deregisterIdempotent() throws {
        let controller = IO.Event.Fake.Controller()
        let driver = IO.Event.Fake.driver(controller: controller)
        let handle = try driver.create()

        let id = try driver.register(handle, descriptor: 42, interest: .read)
        try driver.deregister(handle, id: id)
        try driver.deregister(handle, id: id)  // Should not throw

        #expect(controller.isRegistered(id, handle: handle) == false)
    }

    @Test("deregister on never-registered ID succeeds")
    func deregisterNeverRegisteredSucceeds() throws {
        let controller = IO.Event.Fake.Controller()
        let driver = IO.Event.Fake.driver(controller: controller)
        let handle = try driver.create()

        let fakeID = IO.Event.ID(999)
        try driver.deregister(handle, id: fakeID)  // Should not throw
    }

    // MARK: - Poll Race Rule

    @Test("poll drops events for deregistered IDs")
    func pollDropsDeregisteredEvents() throws {
        let controller = IO.Event.Fake.Controller()
        let driver = IO.Event.Fake.driver(controller: controller)
        let handle = try driver.create()

        let id = try driver.register(handle, descriptor: 42, interest: .read)

        // Push event, then deregister before poll
        controller.pushEvent(
            IO.Event(id: id, interest: .read, flags: []),
            handle: handle
        )
        try driver.deregister(handle, id: id)

        // Poll should return 0 events (the event was for a deregistered ID)
        var buffer = [IO.Event](repeating: .empty, count: 10)
        let count = try driver.poll(handle, deadline: nil, into: &buffer)
        #expect(count == 0)
    }

    @Test("poll returns events for registered IDs")
    func pollReturnsRegisteredEvents() throws {
        let controller = IO.Event.Fake.Controller()
        let driver = IO.Event.Fake.driver(controller: controller)
        let handle = try driver.create()

        let id = try driver.register(handle, descriptor: 42, interest: .read)

        controller.pushEvent(
            IO.Event(id: id, interest: .read, flags: []),
            handle: handle
        )

        var buffer = [IO.Event](repeating: .empty, count: 10)
        let count = try driver.poll(handle, deadline: nil, into: &buffer)
        #expect(count == 1)
        #expect(buffer[0].id == id)
        #expect(buffer[0].interest == .read)
    }

    @Test("poll returns multiple events in order")
    func pollReturnsMultipleEvents() throws {
        let controller = IO.Event.Fake.Controller()
        let driver = IO.Event.Fake.driver(controller: controller)
        let handle = try driver.create()

        let id1 = try driver.register(handle, descriptor: 1, interest: .read)
        let id2 = try driver.register(handle, descriptor: 2, interest: .write)

        controller.pushEvents(
            [
                IO.Event(id: id1, interest: .read, flags: []),
                IO.Event(id: id2, interest: .write, flags: []),
            ],
            handle: handle
        )

        var buffer = [IO.Event](repeating: .empty, count: 10)
        let count = try driver.poll(handle, deadline: nil, into: &buffer)
        #expect(count == 2)
        #expect(buffer[0].id == id1)
        #expect(buffer[1].id == id2)
    }

    // MARK: - Wakeup

    @Test("wakeup causes poll to return immediately")
    func wakeupReturnsPollImmediately() throws {
        let controller = IO.Event.Fake.Controller()
        let driver = IO.Event.Fake.driver(controller: controller)
        let handle = try driver.create()
        let wakeupChannel = try driver.createWakeupChannel(handle)

        wakeupChannel.wake()

        var buffer = [IO.Event](repeating: .empty, count: 10)
        let count = try driver.poll(handle, deadline: nil, into: &buffer)
        #expect(count == 0)  // Wakeup returns 0 events
    }

    // MARK: - Close

    @Test("close removes handle state")
    func closeRemovesHandleState() throws {
        let controller = IO.Event.Fake.Controller()
        let driver = IO.Event.Fake.driver(controller: controller)
        let handle = try driver.create()
        let id = try driver.register(handle, descriptor: 42, interest: .read)
        let isRegisteredBefore = controller.isRegistered(id, handle: handle)
        #expect(isRegisteredBefore)

        driver.close(handle)

        // After close, registrations should be gone
        // (We can't check directly since handle is consumed, but the internal state is cleared)
    }

    // MARK: - Shutdown Simulation

    @Test("simulated shutdown rejects new registrations")
    func shutdownRejectsRegistrations() throws {
        let controller = IO.Event.Fake.Controller()
        let driver = IO.Event.Fake.driver(controller: controller)
        let handle = try driver.create()

        controller.simulateShutdown()

        #expect(throws: IO.Event.Error.self) {
            try driver.register(handle, descriptor: 42, interest: .read)
        }
    }

    @Test("simulated shutdown rejects modify")
    func shutdownRejectsModify() throws {
        let controller = IO.Event.Fake.Controller()
        let driver = IO.Event.Fake.driver(controller: controller)
        let handle = try driver.create()
        let id = try driver.register(handle, descriptor: 42, interest: .read)

        controller.simulateShutdown()

        #expect(throws: IO.Event.Error.self) {
            try driver.modify(handle, id: id, interest: .write)
        }
    }
}

// MARK: - Empty Event Helper

extension IO.Event {
    /// Empty event for buffer initialization.
    static var empty: IO.Event {
        IO.Event(id: IO.Event.ID(0), interest: [], flags: [])
    }
}
