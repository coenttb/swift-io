//
//  IO.Handle.Error Tests.swift
//  swift-io
//

import StandardsTestSupport
import Testing

@testable import IO

extension IO.Handle.Error {
    #TestSuites
}

// MARK: - Unit Tests

extension IO.Handle.Error.Test.Unit {
    @Test("invalidID case exists")
    func invalidIDCase() {
        let error = IO.Handle.Error.invalidID
        #expect(error == .invalidID)
    }

    @Test("scopeMismatch case exists")
    func scopeMismatchCase() {
        let error = IO.Handle.Error.scopeMismatch
        #expect(error == .scopeMismatch)
    }

    @Test("handleClosed case exists")
    func handleClosedCase() {
        let error = IO.Handle.Error.handleClosed
        #expect(error == .handleClosed)
    }

    @Test("waitersFull case exists")
    func waitersFullCase() {
        let error = IO.Handle.Error.waitersFull
        #expect(error == .waitersFull)
    }

    @Test("Equatable conformance")
    func equatableConformance() {
        #expect(IO.Handle.Error.invalidID == .invalidID)
        #expect(IO.Handle.Error.invalidID != .scopeMismatch)
    }

    @Test("Sendable conformance")
    func sendableConformance() async {
        let error = IO.Handle.Error.invalidID
        await Task {
            #expect(error == .invalidID)
        }.value
    }

    @Test("Error conformance")
    func errorConformance() {
        // Compiles only if IO.Handle.Error conforms to Error
        func assertConformsToError<T: Error>(_: T) {}
        assertConformsToError(IO.Handle.Error.invalidID)
    }
}

// MARK: - Edge Cases

extension IO.Handle.Error.Test.EdgeCase {
    @Test("all cases are distinct")
    func allCasesDistinct() {
        let cases: [IO.Handle.Error] = [
            .invalidID,
            .scopeMismatch,
            .handleClosed,
            .waitersFull,
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
