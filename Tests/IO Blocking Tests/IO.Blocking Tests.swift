//
//  IO.Blocking Tests.swift
//  swift-io
//

import StandardsTestSupport
import Testing

@testable import IO_Blocking

extension IO.Blocking {
    #TestSuites
}

// MARK: - Unit Tests

extension IO.Blocking.Test.Unit {
    @Test("namespace exists")
    func namespaceExists() {
        // IO.Blocking is a namespace enum, verified by compilation
    }
}
