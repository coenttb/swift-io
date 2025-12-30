//
//  IO.Memory Tests.swift
//  swift-io
//

import StandardsTestSupport
import Testing

@testable import IO

extension IO.Memory {
    #TestSuites
}

// MARK: - Unit Tests

extension IO.Memory.Test.Unit {
    @Test("namespace exists")
    func namespaceExists() {
        // IO.Memory is a namespace enum, verified by compilation
    }
}
