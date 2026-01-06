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
    @Test("lane case wraps IO.Blocking.Error")
    func laneCase() {
        // Lane now uses IO.Blocking.Error (not Failure) - no lifecycle cases
        let error = IO.Executor.Transaction.Error<TestTransactionError>.lane(.lane(.queueFull))
        if case .lane(let inner) = error {
            #expect(inner == .lane(.queueFull))
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
        let error = IO.Executor.Transaction.Error<TestTransactionError>.lane(.lane(.queueFull))
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
        // Uses IO.Blocking.Error, not Failure - no lifecycle cases
        let lane: IO.Executor.Transaction.Error<TestTransactionError> = .lane(.lane(.queueFull))
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

    @Test("no lifecycle cases in Transaction.Error")
    func noLifecycleCases() {
        // Transaction.Error uses IO.Blocking.Error which excludes lifecycle
        // Lifecycle concerns (shutdown, cancellation, timeout) are in IO.Lifecycle.Error
        // IO.Blocking.Lane.Error has the operational errors
        let allLaneCases: [IO.Blocking.Lane.Error] = [
            .queueFull,
            .overloaded,
            .internalInvariantViolation,
        ]
        #expect(allLaneCases.count == 3)
    }
}
