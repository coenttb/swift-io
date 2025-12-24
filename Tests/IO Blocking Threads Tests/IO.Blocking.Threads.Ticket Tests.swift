//
//  IO.Blocking.Threads.Ticket Tests.swift
//  swift-io
//

import StandardsTestSupport
import Testing

@testable import IO_Blocking_Threads

extension IO.Blocking.Threads.Ticket {
    #TestSuites
}

// MARK: - Unit Tests

extension IO.Blocking.Threads.Ticket.Test.Unit {
    @Test("init with rawValue")
    func initWithRawValue() {
        let ticket = IO.Blocking.Threads.Ticket(rawValue: 42)
        #expect(ticket.rawValue == 42)
    }

    @Test("Hashable conformance - equal")
    func hashableEqual() {
        let ticket1 = IO.Blocking.Threads.Ticket(rawValue: 1)
        let ticket2 = IO.Blocking.Threads.Ticket(rawValue: 1)
        #expect(ticket1.hashValue == ticket2.hashValue)
    }

    @Test("Hashable conformance - not equal")
    func hashableNotEqual() {
        let ticket1 = IO.Blocking.Threads.Ticket(rawValue: 1)
        let ticket2 = IO.Blocking.Threads.Ticket(rawValue: 2)
        #expect(ticket1 != ticket2)
    }

    @Test("Equatable conformance")
    func equatableConformance() {
        let ticket1 = IO.Blocking.Threads.Ticket(rawValue: 100)
        let ticket2 = IO.Blocking.Threads.Ticket(rawValue: 100)
        #expect(ticket1 == ticket2)
    }

    @Test("Sendable conformance")
    func sendableConformance() async {
        let ticket = IO.Blocking.Threads.Ticket(rawValue: 42)
        await Task {
            #expect(ticket.rawValue == 42)
        }.value
    }

    @Test("use as dictionary key")
    func useAsDictionaryKey() {
        let ticket1 = IO.Blocking.Threads.Ticket(rawValue: 1)
        let ticket2 = IO.Blocking.Threads.Ticket(rawValue: 2)
        var dict: [IO.Blocking.Threads.Ticket: String] = [:]
        dict[ticket1] = "first"
        dict[ticket2] = "second"
        #expect(dict[ticket1] == "first")
        #expect(dict[ticket2] == "second")
    }

    @Test("use in Set")
    func useInSet() {
        let ticket1 = IO.Blocking.Threads.Ticket(rawValue: 1)
        let ticket2 = IO.Blocking.Threads.Ticket(rawValue: 1)
        let ticket3 = IO.Blocking.Threads.Ticket(rawValue: 2)
        let set: Set<IO.Blocking.Threads.Ticket> = [ticket1, ticket2, ticket3]
        #expect(set.count == 2)
    }
}

// MARK: - Edge Cases

extension IO.Blocking.Threads.Ticket.Test.EdgeCase {
    @Test("zero rawValue")
    func zeroRawValue() {
        let ticket = IO.Blocking.Threads.Ticket(rawValue: 0)
        #expect(ticket.rawValue == 0)
    }

    @Test("max rawValue")
    func maxRawValue() {
        let ticket = IO.Blocking.Threads.Ticket(rawValue: UInt64.max)
        #expect(ticket.rawValue == UInt64.max)
    }
}
