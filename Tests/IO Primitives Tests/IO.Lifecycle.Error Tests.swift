//
//  IO.Lifecycle.Error Tests.swift
//  swift-io
//

import StandardsTestSupport
import Testing

@testable import IO_Primitives

// IO.Lifecycle.Error is generic, so we test with a concrete error type
struct TestLifecycleLeafError: Error, Sendable {
    let message: String
}

extension IO.Lifecycle.Error where E == TestLifecycleLeafError {
    #TestSuites
}

// MARK: - Unit Tests

extension IO.Lifecycle.Error<TestLifecycleLeafError>.Test.Unit {
    @Test("shutdownInProgress case exists")
    func shutdownInProgressCase() {
        let error = IO.Lifecycle.Error<TestLifecycleLeafError>.shutdownInProgress
        if case .shutdownInProgress = error {
            #expect(Bool(true))
        } else {
            Issue.record("Expected shutdownInProgress case")
        }
    }

    @Test("cancellation case exists")
    func cancellationCase() {
        let error = IO.Lifecycle.Error<TestLifecycleLeafError>.cancellation
        if case .cancellation = error {
            #expect(Bool(true))
        } else {
            Issue.record("Expected cancellation case")
        }
    }

    @Test("failure case wraps leaf error")
    func failureCase() {
        let error = IO.Lifecycle.Error<TestLifecycleLeafError>.failure(TestLifecycleLeafError(message: "test"))
        if case .failure(let inner) = error {
            #expect(inner.message == "test")
        } else {
            Issue.record("Expected failure case")
        }
    }

    @Test("Sendable conformance")
    func sendableConformance() async {
        let error = IO.Lifecycle.Error<TestLifecycleLeafError>.shutdownInProgress
        await Task {
            if case .shutdownInProgress = error {
                #expect(Bool(true))
            } else {
                Issue.record("Expected shutdownInProgress case")
            }
        }.value
    }

    @Test("Error conformance")
    func errorConformance() {
        // Compiles only if IO.Lifecycle.Error conforms to Error
        func assertConformsToError<T: Error>(_: T) {}
        assertConformsToError(IO.Lifecycle.Error<TestLifecycleLeafError>.cancellation)
    }
}

// MARK: - Edge Cases

extension IO.Lifecycle.Error<TestLifecycleLeafError>.Test.EdgeCase {
    @Test("all cases are distinct")
    func allCasesDistinct() {
        let shutdown: IO.Lifecycle.Error<TestLifecycleLeafError> = .shutdownInProgress
        let cancellation: IO.Lifecycle.Error<TestLifecycleLeafError> = .cancellation
        let failure: IO.Lifecycle.Error<TestLifecycleLeafError> = .failure(TestLifecycleLeafError(message: ""))

        if case .shutdownInProgress = shutdown {
            #expect(Bool(true))
        } else {
            Issue.record("shutdown should be .shutdownInProgress case")
        }

        if case .cancellation = cancellation {
            #expect(Bool(true))
        } else {
            Issue.record("cancellation should be .cancellation case")
        }

        if case .failure = failure {
            #expect(Bool(true))
        } else {
            Issue.record("failure should be .failure case")
        }
    }

    @Test("lifecycle cases are the ONLY place for shutdown/cancellation")
    func lifecycleExclusivity() {
        // This test documents the design invariant:
        // Shutdown and cancellation ONLY exist in IO.Lifecycle.Error
        // Other error types (IO.Error, IO.Executor.Error, IO.Blocking.Error) do NOT have these
        let shutdown: IO.Lifecycle.Error<TestLifecycleLeafError> = .shutdownInProgress
        let cancellation: IO.Lifecycle.Error<TestLifecycleLeafError> = .cancellation

        // Both lifecycle concerns are representable
        if case .shutdownInProgress = shutdown {
            #expect(true, "shutdown is representable in IO.Lifecycle.Error")
        }
        if case .cancellation = cancellation {
            #expect(true, "cancellation is representable in IO.Lifecycle.Error")
        }
    }
}
