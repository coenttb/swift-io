//
//  IO.Blocking.Threads.Job Tests.swift
//  swift-io
//

import StandardsTestSupport
import Testing

@testable import IO_Blocking_Threads

extension IO.Blocking.Threads.Job {
    #TestSuites
}

// MARK: - Unit Tests

extension IO.Blocking.Threads.Job.Test.Unit {
    @Test("namespace exists")
    func namespaceExists() {
        // IO.Blocking.Threads.Job is a namespace enum, verified by compilation
    }
}
