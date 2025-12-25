//
//  IO.Blocking.Box Tests.swift
//  swift-io
//

import StandardsTestSupport
import Testing

@testable import IO_Blocking

extension IO.Blocking.Box {
    #TestSuites
}

// MARK: - Unit Tests

extension IO.Blocking.Box.Test.Unit {
    @Test("type exists")
    func typeExists() {
        // IO.Blocking.Box is the type-erased boxing for lane results
        // This test verifies compilation
    }
}
