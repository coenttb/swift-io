//
//  IO.Event.Bridge.Tests.swift
//  swift-io
//

import StandardsTestSupport
import Testing

@testable import IO_Events

// MARK: - Event.Bridge Tests

extension IO.Event.Bridge {
    #TestSuites
}

extension IO.Event.Bridge.Test.Unit {
    @Test("next returns nil after shutdown")
    func nextReturnsNilAfterShutdown() async {
        let bridge = IO.Event.Bridge()
        bridge.shutdown()
        let result = await bridge.next()
        #expect(result == nil)
    }

    @Test("push after shutdown is ignored")
    func pushAfterShutdownIsIgnored() async {
        let bridge = IO.Event.Bridge()
        bridge.shutdown()

        // Push should be silently ignored
        let event = IO.Event(
            id: IO.Event.ID(raw: 1),
            interest: .read,
            flags: []
        )
        bridge.push([event])

        // next() should still return nil (no queued events)
        let result = await bridge.next()
        #expect(result == nil)
    }

    @Test("push then next returns batch")
    func pushThenNextReturnsBatch() async {
        let bridge = IO.Event.Bridge()
        let event = IO.Event(
            id: IO.Event.ID(raw: 42),
            interest: .read,
            flags: []
        )
        bridge.push([event])

        let batch = await bridge.next()
        #expect(batch != nil)
        #expect(batch?.count == 1)
        #expect(batch?.first?.id.raw == 42)

        bridge.shutdown()
    }

    @Test("next then push resumes exactly once")
    func nextThenPushResumesExactlyOnce() async {
        let bridge = IO.Event.Bridge()

        // Start awaiting in background
        async let batchTask = bridge.next()

        // Small yield to ensure next() has suspended
        try? await Task.sleep(for: .milliseconds(10))

        // Push should resume the awaiting task
        let event = IO.Event(
            id: IO.Event.ID(raw: 99),
            interest: .write,
            flags: []
        )
        bridge.push([event])

        let batch = await batchTask
        #expect(batch != nil)
        #expect(batch?.first?.id.raw == 99)

        bridge.shutdown()
    }
}

extension IO.Event.Bridge.Test.EdgeCase {
    @Test("multiple pushes queue correctly")
    func multiplePushesQueueCorrectly() async {
        let bridge = IO.Event.Bridge()

        let event1 = IO.Event(id: IO.Event.ID(raw: 1), interest: .read, flags: [])
        let event2 = IO.Event(id: IO.Event.ID(raw: 2), interest: .write, flags: [])

        bridge.push([event1])
        bridge.push([event2])

        let batch1 = await bridge.next()
        let batch2 = await bridge.next()

        #expect(batch1?.first?.id.raw == 1)
        #expect(batch2?.first?.id.raw == 2)

        bridge.shutdown()
    }

    @Test("shutdown while awaiting next returns nil")
    func shutdownWhileAwaitingNextReturnsNil() async {
        let bridge = IO.Event.Bridge()

        async let batchTask = bridge.next()

        // Small yield to ensure next() has suspended
        try? await Task.sleep(for: .milliseconds(10))

        bridge.shutdown()

        let batch = await batchTask
        #expect(batch == nil)
    }
}

// MARK: - Registration.Reply.Bridge Tests

extension IO.Event.Registration.Reply.Bridge {
    #TestSuites
}

extension IO.Event.Registration.Reply.Bridge.Test.Unit {
    @Test("next returns nil after shutdown")
    func nextReturnsNilAfterShutdown() async {
        let bridge = IO.Event.Registration.Reply.Bridge()
        bridge.shutdown()
        let result = await bridge.next()
        #expect(result == nil)
    }

    @Test("push after shutdown is ignored")
    func pushAfterShutdownIsIgnored() async {
        let bridge = IO.Event.Registration.Reply.Bridge()
        bridge.shutdown()

        let reply = IO.Event.Registration.Reply(
            id: IO.Event.Registration.ReplyID(raw: 1),
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
            id: IO.Event.Registration.ReplyID(raw: 42),
            result: .success(.registered(IO.Event.ID(raw: 100)))
        )
        bridge.push(reply)

        let received = await bridge.next()
        #expect(received != nil)
        #expect(received?.id.raw == 42)
        if case .success(.registered(let id)) = received?.result {
            #expect(id.raw == 100)
        } else {
            Issue.record("Expected .registered payload")
        }

        bridge.shutdown()
    }

    @Test("next then push resumes exactly once")
    func nextThenPushResumesExactlyOnce() async {
        let bridge = IO.Event.Registration.Reply.Bridge()

        async let replyTask = bridge.next()

        try? await Task.sleep(for: .milliseconds(10))

        let reply = IO.Event.Registration.Reply(
            id: IO.Event.Registration.ReplyID(raw: 77),
            result: .success(.modified)
        )
        bridge.push(reply)

        let received = await replyTask
        #expect(received != nil)
        #expect(received?.id.raw == 77)

        bridge.shutdown()
    }
}

extension IO.Event.Registration.Reply.Bridge.Test.EdgeCase {
    @Test("multiple pushes queue correctly")
    func multiplePushesQueueCorrectly() async {
        let bridge = IO.Event.Registration.Reply.Bridge()

        let reply1 = IO.Event.Registration.Reply(
            id: IO.Event.Registration.ReplyID(raw: 1),
            result: .success(.registered(IO.Event.ID(raw: 10)))
        )
        let reply2 = IO.Event.Registration.Reply(
            id: IO.Event.Registration.ReplyID(raw: 2),
            result: .success(.deregistered)
        )

        bridge.push(reply1)
        bridge.push(reply2)

        let received1 = await bridge.next()
        let received2 = await bridge.next()

        #expect(received1?.id.raw == 1)
        #expect(received2?.id.raw == 2)

        bridge.shutdown()
    }

    @Test("shutdown while awaiting next returns nil")
    func shutdownWhileAwaitingNextReturnsNil() async {
        let bridge = IO.Event.Registration.Reply.Bridge()

        async let replyTask = bridge.next()

        try? await Task.sleep(for: .milliseconds(10))

        bridge.shutdown()

        let reply = await replyTask
        #expect(reply == nil)
    }

    @Test("error replies are delivered correctly")
    func errorRepliesDeliveredCorrectly() async {
        let bridge = IO.Event.Registration.Reply.Bridge()

        let reply = IO.Event.Registration.Reply(
            id: IO.Event.Registration.ReplyID(raw: 5),
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

        bridge.shutdown()
    }
}
