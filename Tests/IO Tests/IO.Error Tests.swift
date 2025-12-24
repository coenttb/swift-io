//
//  IO.Error Tests.swift
//  swift-io
//

import StandardsTestSupport
import Testing

@testable import IO

// IO.Error is generic, so we test with a concrete error type
struct TestOperationError: Error, Sendable, Equatable {
    let message: String
}

extension IO.Error where Operation == TestOperationError {
    #TestSuites
}

// MARK: - Unit Tests

extension IO.Error<TestOperationError>.Test.Unit {
    @Test("operation case wraps error")
    func operationCase() {
        let error = IO.Error<TestOperationError>.operation(TestOperationError(message: "test"))
        if case .operation(let inner) = error {
            #expect(inner.message == "test")
        } else {
            Issue.record("Expected operation case")
        }
    }

    @Test("handle case wraps handle error")
    func handleCase() {
        let error = IO.Error<TestOperationError>.handle(.invalidID)
        if case .handle(let inner) = error {
            #expect(inner == .invalidID)
        } else {
            Issue.record("Expected handle case")
        }
    }

    @Test("executor case wraps executor error")
    func executorCase() {
        let error = IO.Error<TestOperationError>.executor(.shutdownInProgress)
        if case .executor(let inner) = error {
            #expect(inner == .shutdownInProgress)
        } else {
            Issue.record("Expected executor case")
        }
    }

    @Test("lane case wraps failure")
    func laneCase() {
        let error = IO.Error<TestOperationError>.lane(.cancelled)
        if case .lane(let inner) = error {
            #expect(inner == .cancelled)
        } else {
            Issue.record("Expected lane case")
        }
    }

    @Test("cancelled case exists")
    func cancelledCase() {
        let error = IO.Error<TestOperationError>.cancelled
        if case .cancelled = error {
            #expect(true)
        } else {
            Issue.record("Expected cancelled case")
        }
    }

    @Test("mapOperation transforms operation error")
    func mapOperation() {
        let error = IO.Error<TestOperationError>.operation(TestOperationError(message: "original"))
        let mapped = error.mapOperation { _ in TestOperationError(message: "mapped") }
        if case .operation(let inner) = mapped {
            #expect(inner.message == "mapped")
        } else {
            Issue.record("Expected operation case")
        }
    }

    @Test("mapOperation preserves non-operation cases")
    func mapOperationPreserves() {
        let error = IO.Error<TestOperationError>.cancelled
        let mapped = error.mapOperation { _ in TestOperationError(message: "should not be called") }
        if case .cancelled = mapped {
            #expect(true)
        } else {
            Issue.record("Expected cancelled case preserved")
        }
    }

    @Test("CustomStringConvertible description")
    func description() {
        let error = IO.Error<TestOperationError>.operation(TestOperationError(message: "test"))
        #expect(error.description.contains("Operation error"))
    }
}

// MARK: - Edge Cases

extension IO.Error<TestOperationError>.Test.EdgeCase {
    @Test("all cases are distinct")
    func allCasesDistinct() {
        let operation: IO.Error<TestOperationError> = .operation(TestOperationError(message: ""))
        let handle: IO.Error<TestOperationError> = .handle(.invalidID)
        let executor: IO.Error<TestOperationError> = .executor(.shutdownInProgress)
        let lane: IO.Error<TestOperationError> = .lane(.cancelled)
        let cancelled: IO.Error<TestOperationError> = .cancelled

        // Verify distinct via switch pattern
        switch operation {
        case .operation: #expect(true)
        default: Issue.record("Wrong case")
        }
        switch handle {
        case .handle: #expect(true)
        default: Issue.record("Wrong case")
        }
        switch executor {
        case .executor: #expect(true)
        default: Issue.record("Wrong case")
        }
        switch lane {
        case .lane: #expect(true)
        default: Issue.record("Wrong case")
        }
        switch cancelled {
        case .cancelled: #expect(true)
        default: Issue.record("Wrong case")
        }
    }
}
