//
//  IO.Memory.Map.Error Tests.swift
//  swift-io
//

import StandardsTestSupport
import Testing

@testable import IO_Primitives

extension IO.Memory.Map.Error {
    #TestSuites
}

// MARK: - Unit Tests

extension IO.Memory.Map.Error.Test.Unit {
    @Test("error cases are distinct")
    func errorCasesDistinct() {
        let errors: [IO.Memory.Map.Error] = [
            .unsupported,
            .invalidRange,
            .invalidAlignment,
            .permissionDenied,
            .outOfMemory,
            .fileTooSmall,
            .mappingSizeLimit,
            .unsupportedConfiguration,
            .invalidHandle,
            .unsupportedFileType,
            .alreadyUnmapped,
        ]

        // Verify all cases are distinct
        for (i, e1) in errors.enumerated() {
            for (j, e2) in errors.enumerated() where i != j {
                #expect(e1 != e2)
            }
        }
    }

    @Test("platform error contains code and message")
    func platformErrorContainsInfo() {
        let error = IO.Memory.Map.Error.platform(code: 42, message: "test error")
        if case .platform(let code, let message) = error {
            #expect(code == 42)
            #expect(message == "test error")
        } else {
            Issue.record("Expected platform error case")
        }
    }

    @Test("error descriptions are non-empty")
    func errorDescriptionsNonEmpty() {
        let errors: [IO.Memory.Map.Error] = [
            .unsupported,
            .invalidRange,
            .invalidAlignment,
            .permissionDenied,
            .outOfMemory,
            .fileTooSmall,
            .mappingSizeLimit,
            .unsupportedConfiguration,
            .invalidHandle,
            .unsupportedFileType,
            .alreadyUnmapped,
            .platform(code: 1, message: "test"),
        ]

        for error in errors {
            #expect(!error.description.isEmpty)
        }
    }

    @Test("error conforms to Error protocol")
    func errorConformsToError() {
        let error: any Swift.Error = IO.Memory.Map.Error.invalidRange
        #expect(error is IO.Memory.Map.Error)
    }

    @Test("error is Sendable")
    func errorIsSendable() {
        let error: IO.Memory.Map.Error = .invalidRange
        let _: any Sendable = error
    }

    @Test("error is Equatable")
    func errorIsEquatable() {
        let e1: IO.Memory.Map.Error = .invalidRange
        let e2: IO.Memory.Map.Error = .invalidRange
        let e3: IO.Memory.Map.Error = .invalidAlignment
        #expect(e1 == e2)
        #expect(e1 != e3)
    }
}
