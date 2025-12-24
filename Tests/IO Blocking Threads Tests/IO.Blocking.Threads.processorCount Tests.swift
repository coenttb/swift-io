//
//  IO.Blocking.Threads.processorCount Tests.swift
//  swift-io
//

import StandardsTestSupport
import Testing

@testable import IO_Blocking_Threads

// Note: processorCount is a static computed property, not a type.
// We create a namespace for testing purposes.
extension IO.Blocking.Threads {
    enum processorCountTests {
        #TestSuites
    }
}

// MARK: - Unit Tests

extension IO.Blocking.Threads.processorCountTests.Test.Unit {
    @Test("processorCount is positive")
    func processorCountPositive() {
        #expect(IO.Blocking.Threads.processorCount >= 1)
    }

    @Test("processorCount is reasonable")
    func processorCountReasonable() {
        // Processor count should be between 1 and some reasonable upper bound
        #expect(IO.Blocking.Threads.processorCount >= 1)
        #expect(IO.Blocking.Threads.processorCount <= 1024)
    }
}
