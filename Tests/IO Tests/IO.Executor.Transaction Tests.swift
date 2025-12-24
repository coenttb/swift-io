//
//  IO.Executor.Transaction Tests.swift
//  swift-io
//

import StandardsTestSupport
import Testing

@testable import IO

extension IO.Executor.Transaction {
    #TestSuites
}

// MARK: - Unit Tests

extension IO.Executor.Transaction.Test.Unit {
    @Test("namespace exists")
    func namespaceExists() {
        // IO.Executor.Transaction is a namespace enum, verified by compilation
    }
}
