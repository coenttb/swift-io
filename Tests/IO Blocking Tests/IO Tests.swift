//
//  IO Tests.swift
//  swift-io
//

import StandardsTestSupport
import Testing

@testable import IO_Blocking

extension IO {
    #TestSuites
}

// MARK: - Unit Tests

extension IO.Test.Unit {
    @Test("namespace re-exported from IO Primitives")
    func namespaceReexported() {
        // IO namespace is re-exported, verified by compilation
    }
}
