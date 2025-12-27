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

    @Test("inline lane run executes non-throwing operation")
    func inlineLaneRunExecutes() async throws {
        let lane = IO.Blocking.Lane.inline
        let result: Int = try await lane.run(deadline: nil) { 42 }
        #expect(result == 42)
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
        let result: String = try await lane.run(deadline: nil) { "test" }
        #expect(result == "test")
    }

    @Test("inline lane with expired deadline throws")
    func inlineExpiredDeadline() async {
        let lane = IO.Blocking.Lane.inline
        let expiredDeadline = IO.Blocking.Deadline.after(nanoseconds: -1_000_000)

        do {
            let _: Int = try await lane.run(deadline: expiredDeadline) { 42 }
            Issue.record("Expected deadlineExceeded error")
        } catch {
            #expect(error == .failure(.deadlineExceeded))
        }
    }

    @Test("inline lane respects cancellation before execution")
    func inlineCancellationBeforeExecution() async {
        let lane = IO.Blocking.Lane.inline

        let task = Task {
            try await Task.sleep(for: .milliseconds(100))
            let result: Int = try await lane.run(deadline: nil) { 42 }
            return result
        }
        task.cancel()

        do {
            _ = try await task.value
            Issue.record("Expected cancelled error")
        } catch {
            // Cancellation should be detected - either CancellationError or lane failure
            #expect(error is CancellationError || (error as? IO.Blocking.Failure) == .cancelled)
        }
    }
}
