//
//  IO.Closure Tests.swift
//  swift-io
//

import StandardsTestSupport
import Testing

@testable import IO

extension IO.Closure {
    #TestSuites
}

// MARK: - Unit Tests

extension IO.Closure.Test.Unit {
    @Test("namespace exists")
    func namespaceExists() {
        // IO.Closure is a namespace enum, verified by compilation
    }
}
