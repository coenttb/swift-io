//
//  IO.Blocking.Lane Tests.swift
//  swift-io
//

import StandardsTestSupport
import Testing

@testable import IO_Blocking

extension IO.Blocking.Lane {
    #TestSuites
}

// MARK: - Unit Tests

extension IO.Blocking.Lane.Test.Unit {
    @Test("inline lane capabilities")
    func inlineLaneCapabilities() {
        let lane = IO.Blocking.Lane.inline
        #expect(lane.capabilities.executesOnDedicatedThreads == false)
        #expect(lane.capabilities.guaranteesRunOnceEnqueued == true)
    }

    @Test("inline lane run executes operation")
    func inlineLaneRunExecutes() async throws {
        let lane = IO.Blocking.Lane.inline
        let result = try await lane.run(deadline: nil) { 42 }
        #expect(result == 42)
    }

    @Test("inline lane run with typed error returns Result")
    func inlineLaneRunTypedError() async throws {
        struct TestError: Error, Equatable {}
        let lane = IO.Blocking.Lane.inline

        let result: Result<Int, TestError> = try await lane.run(deadline: nil) {
            42
        }
        #expect(result == .success(42))
    }

    @Test("inline lane run captures thrown error in Result")
    func inlineLaneRunCapturesError() async throws {
        struct TestError: Error, Equatable {}
        let lane = IO.Blocking.Lane.inline

        let result: Result<Int, TestError> = try await lane.run(deadline: nil) {
            throw TestError()
        }
        #expect(result == .failure(TestError()))
    }

    @Test("inline lane shutdown completes")
    func inlineLaneShutdown() async {
        let lane = IO.Blocking.Lane.inline
        await lane.shutdown()
        // No hang = success
    }

    @Test("Sendable conformance")
    func sendableConformance() async {
        let lane = IO.Blocking.Lane.inline
        await Task {
            #expect(lane.capabilities.guaranteesRunOnceEnqueued == true)
        }.value
    }
}

// MARK: - Edge Cases

extension IO.Blocking.Lane.Test.EdgeCase {
    @Test("inline lane with nil deadline succeeds")
    func inlineNilDeadline() async throws {
        let lane = IO.Blocking.Lane.inline
        let result = try await lane.run(deadline: nil) { "test" }
        #expect(result == "test")
    }

    @Test("inline lane with expired deadline throws")
    func inlineExpiredDeadline() async {
        let lane = IO.Blocking.Lane.inline
        let expiredDeadline = IO.Blocking.Deadline.after(nanoseconds: -1_000_000)

        do {
            _ = try await lane.run(deadline: expiredDeadline) { 42 }
            Issue.record("Expected deadlineExceeded error")
        } catch {
            #expect(error == IO.Blocking.Failure.deadlineExceeded)
        }
    }

    @Test("inline lane respects cancellation before execution")
    func inlineCancellationBeforeExecution() async {
        let lane = IO.Blocking.Lane.inline

        let task = Task {
            try await Task.sleep(for: .milliseconds(100))
            return try await lane.run(deadline: nil) { 42 }
        }
        task.cancel()

        do {
            _ = try await task.value
            Issue.record("Expected cancelled error")
        } catch {
            // Cancellation should be detected
            #expect(error is CancellationError || error == IO.Blocking.Failure.cancelled)
        }
    }
}
