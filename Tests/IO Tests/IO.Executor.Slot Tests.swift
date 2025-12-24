//
//  IO.Executor.Slot Tests.swift
//  swift-io
//

import StandardsTestSupport
import Testing

@testable import IO

extension IO.Executor.Slot {
    #TestSuites
}

// MARK: - Unit Tests

extension IO.Executor.Slot.Test.Unit {
    @Test("namespace exists")
    func namespaceExists() {
        // IO.Executor.Slot is a namespace enum, verified by compilation
    }
}
