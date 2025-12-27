//
//  IO.Executor.Error Tests.swift
//  swift-io
//

import StandardsTestSupport
import Testing

@testable import IO

extension IO.Executor.Error {
    #TestSuites
}

// MARK: - Unit Tests

extension IO.Executor.Error.Test.Unit {
    // Note: shutdownInProgress is no longer a case of IO.Executor.Error.
    // Lifecycle conditions are expressed via IO.Lifecycle.Error at API boundaries.

    @Test("scopeMismatch case exists")
    func scopeMismatchCase() {
        let error = IO.Executor.Error.scopeMismatch
        #expect(error == .scopeMismatch)
    }

    @Test("handleNotFound case exists")
    func handleNotFoundCase() {
        let error = IO.Executor.Error.handleNotFound
        #expect(error == .handleNotFound)
    }

    @Test("invalidState case exists")
    func invalidStateCase() {
        let error = IO.Executor.Error.invalidState
        #expect(error == .invalidState)
    }

    @Test("Equatable conformance")
    func equatableConformance() {
        #expect(IO.Executor.Error.scopeMismatch == .scopeMismatch)
        #expect(IO.Executor.Error.scopeMismatch != .handleNotFound)
    }

    @Test("Sendable conformance")
    func sendableConformance() async {
        let error = IO.Executor.Error.scopeMismatch
        await Task {
            #expect(error == .scopeMismatch)
        }.value
    }

    @Test("Error conformance")
    func errorConformance() {
        let error: any Error = IO.Executor.Error.scopeMismatch
        #expect(error is IO.Executor.Error)
    }
}

// MARK: - Edge Cases

extension IO.Executor.Error.Test.EdgeCase {
    @Test("all cases are distinct")
    func allCasesDistinct() {
        let cases: [IO.Executor.Error] = [
            .scopeMismatch,
            .handleNotFound,
            .invalidState,
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
