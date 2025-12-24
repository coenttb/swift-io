//
//  IO.Handle.Waiters Tests.swift
//  swift-io
//

import StandardsTestSupport
import Testing

@testable import IO

extension IO.Handle.Waiters {
    #TestSuites
}

// MARK: - Unit Tests

extension IO.Handle.Waiters.Test.Unit {
    @Test("type exists")
    func typeExists() {
        // IO.Handle.Waiters is an internal type
        // This test verifies compilation
    }
}
