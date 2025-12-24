//
//  IO.Blocking.Threads.Deadline Tests.swift
//  swift-io
//

import StandardsTestSupport
import Testing

@testable import IO_Blocking_Threads

extension IO.Blocking.Threads.Deadline {
    #TestSuites
}

// MARK: - Unit Tests

extension IO.Blocking.Threads.Deadline.Test.Unit {
    @Test("namespace exists")
    func namespaceExists() {
        // IO.Blocking.Threads.Deadline is a namespace enum, verified by compilation
    }
}
