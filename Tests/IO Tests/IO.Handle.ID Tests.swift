//
//  IO.Handle.ID Tests.swift
//  swift-io
//

import StandardsTestSupport
import Testing

@testable import IO

extension IO.Handle.ID {
    #TestSuites
}

// MARK: - Unit Tests

extension IO.Handle.ID.Test.Unit {
    @Test("init with raw and scope")
    func initWithRawAndScope() {
        let id = IO.Handle.ID(raw: 42, scope: 100)
        #expect(id.raw == 42)
        #expect(id.scope == 100)
    }

    @Test("Hashable conformance - equal")
    func hashableEqual() {
        let id1 = IO.Handle.ID(raw: 1, scope: 10)
        let id2 = IO.Handle.ID(raw: 1, scope: 10)
        #expect(id1.hashValue == id2.hashValue)
    }

    @Test("Hashable conformance - different raw")
    func hashableDifferentRaw() {
        let id1 = IO.Handle.ID(raw: 1, scope: 10)
        let id2 = IO.Handle.ID(raw: 2, scope: 10)
        #expect(id1 != id2)
    }

    @Test("Hashable conformance - different scope")
    func hashableDifferentScope() {
        let id1 = IO.Handle.ID(raw: 1, scope: 10)
        let id2 = IO.Handle.ID(raw: 1, scope: 20)
        #expect(id1 != id2)
    }

    @Test("Equatable conformance")
    func equatableConformance() {
        let id1 = IO.Handle.ID(raw: 100, scope: 200)
        let id2 = IO.Handle.ID(raw: 100, scope: 200)
        #expect(id1 == id2)
    }

    @Test("Sendable conformance")
    func sendableConformance() async {
        let id = IO.Handle.ID(raw: 42, scope: 100)
        await Task {
            #expect(id.raw == 42)
            #expect(id.scope == 100)
        }.value
    }

    @Test("use as dictionary key")
    func useAsDictionaryKey() {
        let id1 = IO.Handle.ID(raw: 1, scope: 10)
        let id2 = IO.Handle.ID(raw: 2, scope: 10)
        var dict: [IO.Handle.ID: String] = [:]
        dict[id1] = "first"
        dict[id2] = "second"
        #expect(dict[id1] == "first")
        #expect(dict[id2] == "second")
    }

    @Test("use in Set")
    func useInSet() {
        let id1 = IO.Handle.ID(raw: 1, scope: 10)
        let id2 = IO.Handle.ID(raw: 1, scope: 10)
        let id3 = IO.Handle.ID(raw: 2, scope: 10)
        let set: Set<IO.Handle.ID> = [id1, id2, id3]
        #expect(set.count == 2)
    }
}

// MARK: - Edge Cases

extension IO.Handle.ID.Test.EdgeCase {
    @Test("zero raw value")
    func zeroRawValue() {
        let id = IO.Handle.ID(raw: 0, scope: 1)
        #expect(id.raw == 0)
    }

    @Test("max raw value")
    func maxRawValue() {
        let id = IO.Handle.ID(raw: UInt64.max, scope: 1)
        #expect(id.raw == UInt64.max)
    }

    @Test("zero scope value")
    func zeroScopeValue() {
        let id = IO.Handle.ID(raw: 1, scope: 0)
        #expect(id.scope == 0)
    }

    @Test("max scope value")
    func maxScopeValue() {
        let id = IO.Handle.ID(raw: 1, scope: UInt64.max)
        #expect(id.scope == UInt64.max)
    }

    @Test("same raw different scope are not equal")
    func sameRawDifferentScope() {
        let id1 = IO.Handle.ID(raw: 42, scope: 1)
        let id2 = IO.Handle.ID(raw: 42, scope: 2)
        #expect(id1 != id2)
    }
}
