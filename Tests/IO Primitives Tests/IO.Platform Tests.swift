//
//  IO.Platform Tests.swift
//  swift-io
//

import Kernel
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
        #expect(Int(IO.Platform.processorCount) >= 1)
    }

    @Test("processorCount is reasonable")
    func processorCountReasonable() {
        // Processor count should be between 1 and some reasonable upper bound
        let count = Int(IO.Platform.processorCount)
        #expect(count >= 1)
        #expect(count <= 1024)
    }
}
