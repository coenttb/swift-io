//
//  IO.Blocking.Threads.Backpressure Tests.swift
//  swift-io
//

import StandardsTestSupport
import Testing

@testable import IO_Blocking_Threads

extension IO.Blocking.Threads.Backpressure {
    #TestSuites
}

// MARK: - Unit Tests

extension IO.Blocking.Threads.Backpressure.Test.Unit {
    @Test("suspend case exists")
    func suspendCase() {
        let backpressure = IO.Blocking.Threads.Backpressure.suspend
        #expect(backpressure == .suspend)
    }

    @Test("throw case exists")
    func throwCase() {
        let backpressure = IO.Blocking.Threads.Backpressure.throw
        #expect(backpressure == .throw)
    }

    @Test("cases are distinct")
    func casesDistinct() {
        #expect(IO.Blocking.Threads.Backpressure.suspend != .throw)
    }

    @Test("Sendable conformance")
    func sendableConformance() async {
        let backpressure = IO.Blocking.Threads.Backpressure.suspend
        await Task {
            #expect(backpressure == .suspend)
        }.value
    }
}

// MARK: - Edge Cases

extension IO.Blocking.Threads.Backpressure.Test.EdgeCase {
    @Test("switch exhaustiveness")
    func switchExhaustiveness() {
        let backpressure = IO.Blocking.Threads.Backpressure.suspend
        switch backpressure {
        case .suspend:
            #expect(true)
        case .throw:
            Issue.record("Unexpected case")
        }
    }
}
