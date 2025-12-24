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
            .queueFull,
            .deadlineExceeded,
            .cancelled,
            .overloaded,
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
