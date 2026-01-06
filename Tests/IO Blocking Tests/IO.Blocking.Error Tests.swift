//
//  IO.Blocking.Error Tests.swift
//  swift-io
//

import StandardsTestSupport
import Testing

@testable import IO_Blocking

extension IO.Blocking.Error {
    #TestSuites
}

// MARK: - Unit Tests

extension IO.Blocking.Error.Test.Unit {
    @Test("lane case wraps Lane.Error")
    func laneCase() {
        let error = IO.Blocking.Error.lane(.queueFull)
        if case .lane(let inner) = error {
            #expect(inner == .queueFull)
        } else {
            Issue.record("Expected lane case")
        }
    }

    @Test("lane queueFull case")
    func laneQueueFull() {
        let error = IO.Blocking.Error.lane(.queueFull)
        if case .lane(.queueFull) = error {
            #expect(Bool(true))
        } else {
            Issue.record("Expected lane queueFull case")
        }
    }

    @Test("lane overloaded case")
    func laneOverloaded() {
        let error = IO.Blocking.Error.lane(.overloaded)
        if case .lane(.overloaded) = error {
            #expect(Bool(true))
        } else {
            Issue.record("Expected lane overloaded case")
        }
    }

    @Test("lane internalInvariantViolation case")
    func laneInternalInvariantViolation() {
        let error = IO.Blocking.Error.lane(.internalInvariantViolation)
        if case .lane(.internalInvariantViolation) = error {
            #expect(Bool(true))
        } else {
            Issue.record("Expected lane internalInvariantViolation case")
        }
    }

    @Test("Sendable conformance")
    func sendableConformance() async {
        let error = IO.Blocking.Error.lane(.queueFull)
        await Task {
            if case .lane(.queueFull) = error {
                #expect(Bool(true))
            } else {
                Issue.record("Expected lane queueFull case")
            }
        }.value
    }

    @Test("Error conformance")
    func errorConformance() {
        // Compiles only if IO.Blocking.Error conforms to Error
        func assertConformsToError<T: Error>(_: T) {}
        assertConformsToError(IO.Blocking.Error.lane(.queueFull))
    }
}

// MARK: - Edge Cases

extension IO.Blocking.Error.Test.EdgeCase {
    @Test("lane error cases are distinct")
    func laneCasesDistinct() {
        let cases: [IO.Blocking.Lane.Error] = [
            .queueFull,
            .overloaded,
            .internalInvariantViolation,
        ]
        #expect(cases.count == 3)

        // Verify each case matches expected pattern
        for (i, error) in cases.enumerated() {
            switch error {
            case .queueFull:
                #expect(i == 0)
            case .overloaded:
                #expect(i == 1)
            case .internalInvariantViolation:
                #expect(i == 2)
            }
        }
    }

    @Test("no lifecycle cases in Lane.Error")
    func noLifecycleCasesInLaneError() {
        // This test documents the design invariant:
        // IO.Blocking.Lane.Error has only operational errors
        // Lifecycle concerns (shutdown/cancellation/timeout) are in IO.Lifecycle.Error
        let allCases: [IO.Blocking.Lane.Error] = [
            .queueFull,
            .overloaded,
            .internalInvariantViolation,
        ]
        // All 3 cases are operational - no lifecycle
        #expect(allCases.count == 3)
    }
}
