//
//  IO.Blocking.Capabilities Tests.swift
//  swift-io
//

import StandardsTestSupport
import Testing

@testable import IO_Blocking

extension IO.Blocking.Capabilities {
    #TestSuites
}

// MARK: - Unit Tests

extension IO.Blocking.Capabilities.Test.Unit {
    @Test("init sets properties correctly")
    func initSetsProperties() {
        let caps = IO.Blocking.Capabilities(
            executesOnDedicatedThreads: true,
            guaranteesRunOnceEnqueued: false
        )
        #expect(caps.executesOnDedicatedThreads == true)
        #expect(caps.guaranteesRunOnceEnqueued == false)
    }

    @Test("Equatable conformance - equal")
    func equatableEqual() {
        let caps1 = IO.Blocking.Capabilities(
            executesOnDedicatedThreads: true,
            guaranteesRunOnceEnqueued: true
        )
        let caps2 = IO.Blocking.Capabilities(
            executesOnDedicatedThreads: true,
            guaranteesRunOnceEnqueued: true
        )
        #expect(caps1 == caps2)
    }

    @Test("Equatable conformance - not equal")
    func equatableNotEqual() {
        let caps1 = IO.Blocking.Capabilities(
            executesOnDedicatedThreads: true,
            guaranteesRunOnceEnqueued: true
        )
        let caps2 = IO.Blocking.Capabilities(
            executesOnDedicatedThreads: false,
            guaranteesRunOnceEnqueued: true
        )
        #expect(caps1 != caps2)
    }

    @Test("Sendable conformance")
    func sendableConformance() async {
        let caps = IO.Blocking.Capabilities(
            executesOnDedicatedThreads: true,
            guaranteesRunOnceEnqueued: true
        )
        await Task {
            #expect(caps.executesOnDedicatedThreads == true)
        }.value
    }
}

// MARK: - Edge Cases

extension IO.Blocking.Capabilities.Test.EdgeCase {
    @Test("all false capabilities")
    func allFalse() {
        let caps = IO.Blocking.Capabilities(
            executesOnDedicatedThreads: false,
            guaranteesRunOnceEnqueued: false
        )
        #expect(caps.executesOnDedicatedThreads == false)
        #expect(caps.guaranteesRunOnceEnqueued == false)
    }

    @Test("all true capabilities")
    func allTrue() {
        let caps = IO.Blocking.Capabilities(
            executesOnDedicatedThreads: true,
            guaranteesRunOnceEnqueued: true
        )
        #expect(caps.executesOnDedicatedThreads == true)
        #expect(caps.guaranteesRunOnceEnqueued == true)
    }
}
