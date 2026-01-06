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
            executionSemantics: .bestEffort
        )
        #expect(caps.executesOnDedicatedThreads == true)
        #expect(caps.executionSemantics == .bestEffort)
    }

    @Test("Equatable conformance - equal")
    func equatableEqual() {
        let caps1 = IO.Blocking.Capabilities(
            executesOnDedicatedThreads: true,
            executionSemantics: .guaranteed
        )
        let caps2 = IO.Blocking.Capabilities(
            executesOnDedicatedThreads: true,
            executionSemantics: .guaranteed
        )
        #expect(caps1 == caps2)
    }

    @Test("Equatable conformance - not equal")
    func equatableNotEqual() {
        let caps1 = IO.Blocking.Capabilities(
            executesOnDedicatedThreads: true,
            executionSemantics: .guaranteed
        )
        let caps2 = IO.Blocking.Capabilities(
            executesOnDedicatedThreads: false,
            executionSemantics: .guaranteed
        )
        #expect(caps1 != caps2)
    }

    @Test("Sendable conformance")
    func sendableConformance() async {
        let caps = IO.Blocking.Capabilities(
            executesOnDedicatedThreads: true,
            executionSemantics: .guaranteed
        )
        await Task {
            #expect(caps.executesOnDedicatedThreads == true)
        }.value
    }
}

// MARK: - Edge Cases

extension IO.Blocking.Capabilities.Test.EdgeCase {
    @Test("weakest semantics capabilities")
    func weakestSemantics() {
        let caps = IO.Blocking.Capabilities(
            executesOnDedicatedThreads: false,
            executionSemantics: .abandonOnExecutionTimeout
        )
        #expect(caps.executesOnDedicatedThreads == false)
        #expect(caps.executionSemantics == .abandonOnExecutionTimeout)
    }

    @Test("strongest semantics capabilities")
    func strongestSemantics() {
        let caps = IO.Blocking.Capabilities(
            executesOnDedicatedThreads: true,
            executionSemantics: .guaranteed
        )
        #expect(caps.executesOnDedicatedThreads == true)
        #expect(caps.executionSemantics == .guaranteed)
    }
}
