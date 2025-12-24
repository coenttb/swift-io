//
//  IO.Executor.Handle Tests.swift
//  swift-io
//

import StandardsTestSupport
import Testing

@testable import IO

extension IO.Executor.Handle {
    #TestSuites
}

// MARK: - Unit Tests

extension IO.Executor.Handle.Test.Unit {
    @Test("namespace exists")
    func namespaceExists() {
        // IO.Executor.Handle is a namespace enum, verified by compilation
    }
}
