//
//  IO.Blocking.Threads.Thread Tests.swift
//  swift-io
//

import StandardsTestSupport
import Testing

@testable import IO_Blocking_Threads

extension IO.Blocking.Threads.Thread {
    #TestSuites
}

// MARK: - Unit Tests

extension IO.Blocking.Threads.Thread.Test.Unit {
    @Test("namespace exists")
    func namespaceExists() {
        // IO.Blocking.Threads.Thread is a namespace enum, verified by compilation
    }
}
