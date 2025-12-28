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
    @Test("shutdown case exists")
    func shutdownCase() {
        let failure = IO.Blocking.Failure.shutdown
        #expect(failure == .shutdown)
    }

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

    @Test("cancellationRequested case exists")
    func cancellationRequestedCase() {
        let failure = IO.Blocking.Failure.cancellationRequested
        #expect(failure == .cancellationRequested)
    }

    @Test("overloaded case exists")
    func overloadedCase() {
        let failure = IO.Blocking.Failure.overloaded
        #expect(failure == .overloaded)
    }

    @Test("internalInvariantViolation case exists")
    func internalInvariantViolationCase() {
        let failure = IO.Blocking.Failure.internalInvariantViolation
        #expect(failure == .internalInvariantViolation)
    }

    @Test("Equatable conformance")
    func equatableConformance() {
        #expect(IO.Blocking.Failure.shutdown == IO.Blocking.Failure.shutdown)
        #expect(IO.Blocking.Failure.shutdown != IO.Blocking.Failure.queueFull)
    }

    @Test("Sendable conformance")
    func sendableConformance() async {
        let failure = IO.Blocking.Failure.shutdown
        await Task {
            #expect(failure == .shutdown)
        }.value
    }

    @Test("Error conformance")
    func errorConformance() {
        let failure: any Error = IO.Blocking.Failure.shutdown
        #expect(failure is IO.Blocking.Failure)
    }
}

// MARK: - Edge Cases

extension IO.Blocking.Failure.Test.EdgeCase {
    @Test("all cases are distinct")
    func allCasesDistinct() {
        let cases: [IO.Blocking.Failure] = [
            .shutdown,
            .cancellationRequested,
            .queueFull,
            .deadlineExceeded,
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

    @Test("lifecycle cases (shutdown, cancellationRequested) are internal contract")
    func lifecycleCasesAreInternalContract() {
        // These cases exist in the Lane contract but are mapped to
        // IO.Lifecycle.Error at the Pool boundary.
        // Do not match them directly in user code.
        let shutdown = IO.Blocking.Failure.shutdown
        let cancellation = IO.Blocking.Failure.cancellationRequested
        #expect(shutdown == .shutdown)
        #expect(cancellation == .cancellationRequested)
    }
}
