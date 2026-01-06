//
//  IO.Event.Bridge.Tests.swift
//  swift-io
//

import StandardsTestSupport
import Testing

@testable import IO_Events

// MARK: - Event.Bridge Tests

extension IO.Event.Poll {
    fileprivate var events: [IO.Event]? {
        if case .events(let e) = self { return e }
        return nil
    }
}

@Suite("Event.Bridge")
struct EventBridgeTests {
    @Test("next returns nil after shutdown")
    func nextReturnsNilAfterShutdown() async {
        let bridge = IO.Event.Bridge()
        bridge.finish()
        let result = await bridge.next()
        #expect(result == nil)
    }

    @Test("push after shutdown is ignored")
    func pushAfterShutdownIsIgnored() async {
        let bridge = IO.Event.Bridge()
        bridge.finish()

        let event = IO.Event(
            id: IO.Event.ID(1),
            interest: .read,
            flags: []
        )
        bridge.push(.events([event]))

        let result = await bridge.next()
        #expect(result == nil)
    }

    @Test("push then next returns batch")
    func pushThenNextReturnsBatch() async {
        let bridge = IO.Event.Bridge()
        let event = IO.Event(
            id: IO.Event.ID(42),
            interest: .read,
            flags: []
        )
        bridge.push(.events([event]))

        let batch = await bridge.next()
        #expect(batch != nil)
        #expect(batch?.events?.count == 1)
        #expect(batch?.events?.first?.id.rawValue == 42)

        bridge.finish()
    }

    @Test("next then push resumes exactly once")
    func nextThenPushResumesExactlyOnce() async {
        let bridge = IO.Event.Bridge()

        async let batchTask = bridge.next()

        try? await Task.sleep(for: .milliseconds(10))

        let event = IO.Event(
            id: IO.Event.ID(99),
            interest: .write,
            flags: []
        )
        bridge.push(.events([event]))

        let batch = await batchTask
        #expect(batch != nil)
        #expect(batch?.events?.first?.id.rawValue == 99)

        bridge.finish()
    }

    @Test("multiple pushes queue correctly")
    func multiplePushesQueueCorrectly() async {
        let bridge = IO.Event.Bridge()

        let event1 = IO.Event(id: IO.Event.ID(1), interest: .read, flags: [])
        let event2 = IO.Event(id: IO.Event.ID(2), interest: .write, flags: [])

        bridge.push(.events([event1]))
        bridge.push(.events([event2]))

        let batch1 = await bridge.next()
        let batch2 = await bridge.next()

        #expect(batch1?.events?.first?.id.rawValue == 1)
        #expect(batch2?.events?.first?.id.rawValue == 2)

        bridge.finish()
    }

    @Test("shutdown while awaiting next returns nil")
    func shutdownWhileAwaitingNextReturnsNil() async {
        let bridge = IO.Event.Bridge()

        async let batchTask = bridge.next()

        try? await Task.sleep(for: .milliseconds(10))

        bridge.finish()

        let batch = await batchTask
        #expect(batch == nil)
    }
}

// MARK: - Registration.Reply.Bridge Tests

@Suite("Registration.Reply.Bridge")
struct RegistrationReplyBridgeTests {
    @Test("next returns nil after shutdown")
    func nextReturnsNilAfterShutdown() async {
        let bridge = IO.Event.Registration.Reply.Bridge()
        bridge.finish()
        let result = await bridge.next()
        #expect(result == nil)
    }

    @Test("push after shutdown is ignored")
    func pushAfterShutdownIsIgnored() async {
        let bridge = IO.Event.Registration.Reply.Bridge()
        bridge.finish()

        let reply = IO.Event.Registration.Reply(
            id: IO.Event.Registration.Reply.ID( 1),
            result: .success(.deregistered)
        )
        bridge.push(reply)

        let result = await bridge.next()
        #expect(result == nil)
    }

    @Test("push then next returns reply")
    func pushThenNextReturnsReply() async {
        let bridge = IO.Event.Registration.Reply.Bridge()
        let reply = IO.Event.Registration.Reply(
            id: IO.Event.Registration.Reply.ID( 42),
            result: .success(.registered(IO.Event.ID(100)))
        )
        bridge.push(reply)

        let received = await bridge.next()
        #expect(received != nil)
        #expect(received?.id.rawValue == 42)
        if case .success(.registered(let id)) = received?.result {
            #expect(id.rawValue == 100)
        } else {
            Issue.record("Expected .registered payload")
        }

        bridge.finish()
    }

    @Test("next then push resumes exactly once")
    func nextThenPushResumesExactlyOnce() async {
        let bridge = IO.Event.Registration.Reply.Bridge()

        async let replyTask = bridge.next()

        try? await Task.sleep(for: .milliseconds(10))

        let reply = IO.Event.Registration.Reply(
            id: IO.Event.Registration.Reply.ID( 77),
            result: .success(.modified)
        )
        bridge.push(reply)

        let received = await replyTask
        #expect(received != nil)
        #expect(received?.id.rawValue == 77)

        bridge.finish()
    }

    @Test("multiple pushes queue correctly")
    func multiplePushesQueueCorrectly() async {
        let bridge = IO.Event.Registration.Reply.Bridge()

        let reply1 = IO.Event.Registration.Reply(
            id: IO.Event.Registration.Reply.ID( 1),
            result: .success(.registered(IO.Event.ID(10)))
        )
        let reply2 = IO.Event.Registration.Reply(
            id: IO.Event.Registration.Reply.ID( 2),
            result: .success(.deregistered)
        )

        bridge.push(reply1)
        bridge.push(reply2)

        let received1 = await bridge.next()
        let received2 = await bridge.next()

        #expect(received1?.id.rawValue == 1)
        #expect(received2?.id.rawValue == 2)

        bridge.finish()
    }

    @Test("shutdown while awaiting next returns nil")
    func shutdownWhileAwaitingNextReturnsNil() async {
        let bridge = IO.Event.Registration.Reply.Bridge()

        async let replyTask = bridge.next()

        try? await Task.sleep(for: .milliseconds(10))

        bridge.finish()

        let reply = await replyTask
        #expect(reply == nil)
    }

    @Test("error replies are delivered correctly")
    func errorRepliesDeliveredCorrectly() async {
        let bridge = IO.Event.Registration.Reply.Bridge()

        let reply = IO.Event.Registration.Reply(
            id: IO.Event.Registration.Reply.ID( 5),
            result: .failure(.notRegistered)
        )
        bridge.push(reply)

        let received = await bridge.next()
        #expect(received != nil)
        if case .failure(.notRegistered) = received?.result {
            // Expected
        } else {
            Issue.record("Expected .notRegistered error")
        }

        bridge.finish()
    }
}
