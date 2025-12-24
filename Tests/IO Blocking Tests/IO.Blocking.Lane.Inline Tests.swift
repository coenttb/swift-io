//
//  IO.Blocking.Lane.Inline Tests.swift
//  swift-io
//

import StandardsTestSupport
import Testing

@testable import IO_Blocking

// Note: IO.Blocking.Lane.Inline is a static property extension, not a nested type.
// Tests for .inline are covered in IO.Blocking.Lane Tests.swift.
// This file exists to maintain 1:1 source/test mapping.

extension IO.Blocking.Lane {
    enum Inline {
        #TestSuites
    }
}

// MARK: - Unit Tests

extension IO.Blocking.Lane.Inline.Test.Unit {
    @Test("inline static property exists")
    func inlinePropertyExists() {
        let lane = IO.Blocking.Lane.inline
        #expect(lane.capabilities.executesOnDedicatedThreads == false)
    }

    @Test("inline does not execute on dedicated threads")
    func inlineNotDedicatedThreads() {
        let lane = IO.Blocking.Lane.inline
        #expect(lane.capabilities.executesOnDedicatedThreads == false)
    }

    @Test("inline guarantees run once enqueued")
    func inlineGuaranteesRunOnceEnqueued() {
        let lane = IO.Blocking.Lane.inline
        #expect(lane.capabilities.guaranteesRunOnceEnqueued == true)
    }
}
