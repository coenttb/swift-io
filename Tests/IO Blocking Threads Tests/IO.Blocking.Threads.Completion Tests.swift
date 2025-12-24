//
//  IO.Blocking.Threads.Completion Tests.swift
//  swift-io
//

import StandardsTestSupport
import Testing

@testable import IO_Blocking_Threads

extension IO.Blocking.Threads.Completion {
    #TestSuites
}

// MARK: - Unit Tests

extension IO.Blocking.Threads.Completion.Test.Unit {
    @Test("namespace exists")
    func namespaceExists() {
        // IO.Blocking.Threads.Completion is a namespace enum, verified by compilation
    }
}
