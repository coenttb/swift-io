//
//  IO.Platform Tests.swift
//  swift-io
//

import StandardsTestSupport
import Testing

@testable import IO_Primitives

extension IO.Platform {
    #TestSuites
}

// MARK: - Unit Tests

extension IO.Platform.Test.Unit {
    @Test("processorCount is positive")
    func processorCountPositive() {
        #expect(IO.Platform.processorCount >= 1)
    }

    @Test("processorCount is reasonable")
    func processorCountReasonable() {
        // Processor count should be between 1 and some reasonable upper bound
        #expect(IO.Platform.processorCount >= 1)
        #expect(IO.Platform.processorCount <= 1024)
    }
}
