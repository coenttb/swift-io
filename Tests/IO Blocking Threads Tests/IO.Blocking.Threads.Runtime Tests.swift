//
//  IO.Blocking.Threads.Runtime Tests.swift
//  swift-io
//

import StandardsTestSupport
import Testing

@testable import IO_Blocking_Threads

extension IO.Blocking.Threads.Runtime {
    #TestSuites
}

// MARK: - Unit Tests

extension IO.Blocking.Threads.Runtime.Test.Unit {
    @Test("type exists")
    func typeExists() {
        // IO.Blocking.Threads.Runtime is an internal type
        // This test verifies compilation
    }
}
