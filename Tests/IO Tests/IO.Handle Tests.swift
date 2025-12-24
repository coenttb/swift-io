//
//  IO.Handle Tests.swift
//  swift-io
//

import StandardsTestSupport
import Testing

@testable import IO

extension IO.Handle {
    #TestSuites
}

// MARK: - Unit Tests

extension IO.Handle.Test.Unit {
    @Test("namespace exists")
    func namespaceExists() {
        // IO.Handle is a namespace enum, verified by compilation
    }
}
