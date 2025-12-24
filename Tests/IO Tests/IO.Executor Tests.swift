//
//  IO.Executor Tests.swift
//  swift-io
//

import StandardsTestSupport
import Testing

@testable import IO

extension IO.Executor {
    #TestSuites
}

// MARK: - Unit Tests

extension IO.Executor.Test.Unit {
    @Test("namespace exists")
    func namespaceExists() {
        // IO.Executor is a namespace enum, verified by compilation
    }

    @Test("scopeCounter generates unique values")
    func scopeCounterUnique() {
        let first = IO.Executor.scopeCounter.next()
        let second = IO.Executor.scopeCounter.next()
        #expect(first != second)
    }
}
