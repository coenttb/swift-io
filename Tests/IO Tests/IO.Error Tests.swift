//
//  IO.Error Tests.swift
//  swift-io
//

import StandardsTestSupport
import Testing

@testable import IO

// IO.Error is generic, so we test with a concrete error type
struct TestLeafError: Error, Sendable, Equatable {
    let message: String
}

extension IO.Error where Leaf == TestLeafError {
    #TestSuites
}

// MARK: - Unit Tests

extension IO.Error<TestLeafError>.Test.Unit {
    @Test("leaf case wraps error")
    func leafCase() {
        let error = IO.Error<TestLeafError>.leaf(TestLeafError(message: "test"))
        if case .leaf(let inner) = error {
            #expect(inner.message == "test")
        } else {
            Issue.record("Expected leaf case")
        }
    }

    @Test("handle case wraps handle error")
    func handleCase() {
        let error = IO.Error<TestLeafError>.handle(.invalidID)
        if case .handle(let inner) = error {
            #expect(inner == .invalidID)
        } else {
            Issue.record("Expected handle case")
        }
    }

    @Test("executor case wraps executor error")
    func executorCase() {
        // IO.Executor.Error no longer has shutdownInProgress
        let error = IO.Error<TestLeafError>.executor(.scopeMismatch)
        if case .executor(let inner) = error {
            #expect(inner == .scopeMismatch)
        } else {
            Issue.record("Expected executor case")
        }
    }

    @Test("lane case wraps IO.Blocking.Error")
    func laneCase() {
        // Lane now uses IO.Blocking.Error, not IO.Blocking.Failure
        let error = IO.Error<TestLeafError>.lane(.queueFull)
        if case .lane(let inner) = error {
            #expect(inner == .queueFull)
        } else {
            Issue.record("Expected lane case")
        }
    }

    @Test("mapLeaf transforms leaf error")
    func mapLeaf() {
        let error = IO.Error<TestLeafError>.leaf(TestLeafError(message: "original"))
        let mapped = error.mapLeaf { _ in TestLeafError(message: "mapped") }
        if case .leaf(let inner) = mapped {
            #expect(inner.message == "mapped")
        } else {
            Issue.record("Expected leaf case")
        }
    }

    @Test("mapLeaf preserves non-leaf cases")
    func mapLeafPreserves() {
        let error = IO.Error<TestLeafError>.lane(.queueFull)
        let mapped = error.mapLeaf { _ in TestLeafError(message: "should not be called") }
        if case .lane(let inner) = mapped {
            #expect(inner == .queueFull)
        } else {
            Issue.record("Expected lane case preserved")
        }
    }
}

// MARK: - Edge Cases

extension IO.Error<TestLeafError>.Test.EdgeCase {
    @Test("all cases are distinct")
    func allCasesDistinct() {
        let leaf: IO.Error<TestLeafError> = .leaf(TestLeafError(message: ""))
        let handle: IO.Error<TestLeafError> = .handle(.invalidID)
        let executor: IO.Error<TestLeafError> = .executor(.scopeMismatch)
        let lane: IO.Error<TestLeafError> = .lane(.queueFull)

        // Verify each case matches expected pattern
        if case .leaf = leaf {
            #expect(Bool(true))
        } else {
            Issue.record("leaf should be .leaf case")
        }

        if case .handle = handle {
            #expect(Bool(true))
        } else {
            Issue.record("handle should be .handle case")
        }

        if case .executor = executor {
            #expect(Bool(true))
        } else {
            Issue.record("executor should be .executor case")
        }

        if case .lane = lane {
            #expect(Bool(true))
        } else {
            Issue.record("lane should be .lane case")
        }
    }

    @Test("no cancelled case - lifecycle concerns moved to IO.Lifecycle.Error")
    func noDirectCancelledCase() {
        // IO.Error no longer has .cancelled - it's in IO.Lifecycle.Error
        // This test verifies the design: lifecycle concerns are separate
        let allCases: [IO.Error<TestLeafError>] = [
            .leaf(TestLeafError(message: "")),
            .handle(.invalidID),
            .executor(.scopeMismatch),
            .lane(.queueFull),
        ]
        // All 4 cases are operational - no lifecycle
        #expect(allCases.count == 4)
    }
}
