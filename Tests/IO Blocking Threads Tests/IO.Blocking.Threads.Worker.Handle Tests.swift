//
//  IO.Blocking.Threads.Worker.Handle Tests.swift
//  swift-io
//

import StandardsTestSupport
import Testing

@testable import IO_Blocking_Threads

extension IO.Blocking.Threads.Worker.Handle {
    #TestSuites
}

// MARK: - Unit Tests

extension IO.Blocking.Threads.Worker.Handle.Test.Unit {
    @Test("type exists")
    func typeExists() {
        // IO.Blocking.Threads.Worker.Handle is an internal reference wrapper
        // for ~Copyable Kernel.Thread.Handle. This test verifies compilation.
    }
}
