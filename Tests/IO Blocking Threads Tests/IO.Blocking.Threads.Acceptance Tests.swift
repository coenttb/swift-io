//
//  IO.Blocking.Threads.Acceptance Tests.swift
//  swift-io
//

import StandardsTestSupport
import Testing

@testable import IO_Blocking_Threads

extension IO.Blocking.Threads.Acceptance {
    #TestSuites
}

// MARK: - Unit Tests

extension IO.Blocking.Threads.Acceptance.Test.Unit {
    @Test("namespace exists")
    func namespaceExists() {
        // IO.Blocking.Threads.Acceptance is a namespace enum, verified by compilation
    }
}
