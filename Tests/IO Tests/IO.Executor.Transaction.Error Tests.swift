//
//  IO.Executor.Transaction.Error Tests.swift
//  swift-io
//

import StandardsTestSupport
import Testing

@testable import IO

// Transaction.Error is generic, so we test with a concrete error type
struct TestTransactionError: Error, Sendable, Equatable {
    let code: Int
}

extension IO.Executor.Transaction.Error where E == TestTransactionError {
    #TestSuites
}

// MARK: - Unit Tests

extension IO.Executor.Transaction.Error<TestTransactionError>.Test.Unit {
    @Test("lane case wraps failure")
    func laneCase() {
        let error = IO.Executor.Transaction.Error<TestTransactionError>.lane(.cancelled)
        if case .lane(let inner) = error {
            #expect(inner == .cancelled)
        } else {
            Issue.record("Expected lane case")
        }
    }

    @Test("handle case wraps handle error")
    func handleCase() {
        let error = IO.Executor.Transaction.Error<TestTransactionError>.handle(.invalidID)
        if case .handle(let inner) = error {
            #expect(inner == .invalidID)
        } else {
            Issue.record("Expected handle case")
        }
    }

    @Test("body case wraps body error")
    func bodyCase() {
        let error = IO.Executor.Transaction.Error<TestTransactionError>.body(TestTransactionError(code: 42))
        if case .body(let inner) = error {
            #expect(inner.code == 42)
        } else {
            Issue.record("Expected body case")
        }
    }

    @Test("Sendable conformance")
    func sendableConformance() async {
        let error = IO.Executor.Transaction.Error<TestTransactionError>.lane(.cancelled)
        await Task {
            if case .lane = error {
                #expect(Bool(true))
            } else {
                Issue.record("Expected lane case")
            }
        }.value
    }
}

// MARK: - Edge Cases

extension IO.Executor.Transaction.Error<TestTransactionError>.Test.EdgeCase {
    @Test("all cases are distinct")
    func allCasesDistinct() {
        let lane: IO.Executor.Transaction.Error<TestTransactionError> = .lane(.cancelled)
        let handle: IO.Executor.Transaction.Error<TestTransactionError> = .handle(.invalidID)
        let body: IO.Executor.Transaction.Error<TestTransactionError> = .body(TestTransactionError(code: 1))

        // Verify each case matches expected pattern
        if case .lane = lane {
            #expect(Bool(true))
        } else {
            Issue.record("lane should be .lane case")
        }

        if case .handle = handle {
            #expect(Bool(true))
        } else {
            Issue.record("handle should be .handle case")
        }

        if case .body = body {
            #expect(Bool(true))
        } else {
            Issue.record("body should be .body case")
        }
    }
}
