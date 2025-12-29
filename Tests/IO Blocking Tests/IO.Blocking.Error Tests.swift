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
    @Test("queueFull case exists")
    func queueFullCase() {
        let error = IO.Blocking.Error.queueFull
        if case .queueFull = error {
            #expect(Bool(true))
        } else {
            Issue.record("Expected queueFull case")
        }
    }

    @Test("deadlineExceeded case exists")
    func deadlineExceededCase() {
        let error = IO.Blocking.Error.deadlineExceeded
        if case .deadlineExceeded = error {
            #expect(Bool(true))
        } else {
            Issue.record("Expected deadlineExceeded case")
        }
    }

    @Test("overloaded case exists")
    func overloadedCase() {
        let error = IO.Blocking.Error.overloaded
        if case .overloaded = error {
            #expect(Bool(true))
        } else {
            Issue.record("Expected overloaded case")
        }
    }

    @Test("internalInvariantViolation case exists")
    func internalInvariantViolationCase() {
        let error = IO.Blocking.Error.internalInvariantViolation
        if case .internalInvariantViolation = error {
            #expect(Bool(true))
        } else {
            Issue.record("Expected internalInvariantViolation case")
        }
    }

    @Test("Sendable conformance")
    func sendableConformance() async {
        let error = IO.Blocking.Error.queueFull
        await Task {
            if case .queueFull = error {
                #expect(Bool(true))
            } else {
                Issue.record("Expected queueFull case")
            }
        }.value
    }

    @Test("Error conformance")
    func errorConformance() {
        // Compiles only if IO.Blocking.Error conforms to Error
        func assertConformsToError<T: Error>(_: T) {}
        assertConformsToError(IO.Blocking.Error.queueFull)
    }
}

// MARK: - Edge Cases

extension IO.Blocking.Error.Test.EdgeCase {
    @Test("all cases are distinct")
    func allCasesDistinct() {
        // IO.Blocking.Error has NO lifecycle cases (shutdown/cancelled)
        let cases: [IO.Blocking.Error] = [
            .queueFull,
            .deadlineExceeded,
            .overloaded,
            .internalInvariantViolation,
        ]
        #expect(cases.count == 4)

        // Verify each case matches expected pattern
        for (i, error) in cases.enumerated() {
            switch error {
            case .queueFull:
                #expect(i == 0)
            case .deadlineExceeded:
                #expect(i == 1)
            case .overloaded:
                #expect(i == 2)
            case .internalInvariantViolation:
                #expect(i == 3)
            }
        }
    }

    @Test("no lifecycle cases - shutdown/cancelled excluded")
    func noLifecycleCases() {
        // This test documents the design invariant:
        // IO.Blocking.Error is the PUBLIC subset of IO.Blocking.Failure
        // It excludes lifecycle concerns (shutdown/cancellationRequested)
        // which are mapped to IO.Lifecycle.Error at the Pool boundary
        let allCases: [IO.Blocking.Error] = [
            .queueFull,
            .deadlineExceeded,
            .overloaded,
            .internalInvariantViolation
        ]
        // All 4 cases are operational - no lifecycle
        #expect(allCases.count == 4)
    }

    @Test("failable init from Failure - operational cases map")
    func failableInitFromFailure() {
        // Operational cases map successfully
        #expect(IO.Blocking.Error(.queueFull) == .queueFull)
        #expect(IO.Blocking.Error(.deadlineExceeded) == .deadlineExceeded)
        #expect(IO.Blocking.Error(.overloaded) == .overloaded)
        #expect(IO.Blocking.Error(.internalInvariantViolation) == .internalInvariantViolation)
    }

    @Test("failable init from Failure - lifecycle cases return nil")
    func failableInitFromFailureReturnsNilForLifecycle() {
        // Lifecycle cases return nil - they should be handled separately
        #expect(IO.Blocking.Error(.shutdown) == nil)
        #expect(IO.Blocking.Error(.cancellationRequested) == nil)
    }
}
