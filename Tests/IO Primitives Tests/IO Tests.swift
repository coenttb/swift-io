//
//  IO Tests.swift
//  swift-io
//

import StandardsTestSupport
import Testing

@testable import IO_Primitives

extension IO {
    #TestSuites
}

// MARK: - Unit Tests

extension IO.Test.Unit {
    @Test("namespace exists")
    func namespaceExists() {
        // IO is a namespace enum, verified by compilation
    }
}
