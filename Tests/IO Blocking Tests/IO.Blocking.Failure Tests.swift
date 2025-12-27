//
//  IO.Blocking.Failure Tests.swift
//  swift-io
//

import StandardsTestSupport
import Testing

@testable import IO_Blocking

extension IO.Blocking.Failure {
    #TestSuites
}

// MARK: - Unit Tests

extension IO.Blocking.Failure.Test.Unit {
    // Note: shutdown is no longer a case of IO.Blocking.Failure.
    // Lifecycle conditions are expressed via IO.Lifecycle.Error at API boundaries.

    @Test("queueFull case exists")
    func queueFullCase() {
        let failure = IO.Blocking.Failure.queueFull
        #expect(failure == .queueFull)
    }

    @Test("deadlineExceeded case exists")
    func deadlineExceededCase() {
        let failure = IO.Blocking.Failure.deadlineExceeded
        #expect(failure == .deadlineExceeded)
    }

    @Test("cancelled case exists")
    func cancelledCase() {
        let failure = IO.Blocking.Failure.cancelled
        #expect(failure == .cancelled)
    }

    @Test("overloaded case exists")
    func overloadedCase() {
        let failure = IO.Blocking.Failure.overloaded
        #expect(failure == .overloaded)
    }

    @Test("Equatable conformance")
    func equatableConformance() {
        #expect(IO.Blocking.Failure.queueFull == IO.Blocking.Failure.queueFull)
        #expect(IO.Blocking.Failure.queueFull != IO.Blocking.Failure.cancelled)
    }

    @Test("Sendable conformance")
    func sendableConformance() async {
        let failure = IO.Blocking.Failure.queueFull
        await Task {
            #expect(failure == .queueFull)
        }.value
    }

    @Test("Error conformance")
    func errorConformance() {
        let failure: any Error = IO.Blocking.Failure.queueFull
        #expect(failure is IO.Blocking.Failure)
    }
}

// MARK: - Edge Cases

extension IO.Blocking.Failure.Test.EdgeCase {
    @Test("all cases are distinct")
    func allCasesDistinct() {
        let cases: [IO.Blocking.Failure] = [
            .queueFull,
            .deadlineExceeded,
            .cancelled,
            .overloaded,
            .internalInvariantViolation,
        ]
        for (i, case1) in cases.enumerated() {
            for (j, case2) in cases.enumerated() {
                if i == j {
                    #expect(case1 == case2)
                } else {
                    #expect(case1 != case2)
                }
            }
        }
    }
}
