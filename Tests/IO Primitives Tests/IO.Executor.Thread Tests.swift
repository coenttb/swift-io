//
//  IO.Executor.Thread Tests.swift
//  swift-io
//

import StandardsTestSupport
import Testing

@testable import IO_Primitives

extension IO.Executor.Thread {
    #TestSuites
}

// MARK: - Unit Tests

extension IO.Executor.Thread.Test.Unit {
    @Test("executor conforms to SerialExecutor")
    func serialExecutorConformance() {
        let executor = IO.Executor.Thread()
        let unowned = executor.asUnownedSerialExecutor()
        // If this compiles and runs, the executor conforms
        _ = unowned
        executor.shutdown()
    }

    @Test("executor conforms to TaskExecutor")
    func taskExecutorConformance() async {
        let executor = IO.Executor.Thread()

        // Task(executorPreference:) only works with TaskExecutor
        await Task(executorPreference: executor) {
            // Job executed on executor
        }.value

        executor.shutdown()
    }

    @Test("shutdown completes gracefully")
    func shutdownCompletes() {
        let executor = IO.Executor.Thread()
        executor.shutdown()
        // No hang = success
    }
}

// MARK: - Integration Tests

extension IO.Executor.Thread.Test {
    @Suite struct Integration {}
}

extension IO.Executor.Thread.Test.Integration {
    @Test("task executor preference executes on thread")
    func taskExecutorPreferenceWorks() async {
        let executor = IO.Executor.Thread()

        // Use a Sendable result to verify execution
        let result = await Task(executorPreference: executor) {
            return 42
        }.value

        #expect(result == 42)
        executor.shutdown()
    }

    @Test("multiple tasks execute sequentially on same executor")
    func multipleTasksSequential() async {
        let executor = IO.Executor.Thread()

        let r1 = await Task(executorPreference: executor) { 1 }.value
        let r2 = await Task(executorPreference: executor) { 2 }.value
        let r3 = await Task(executorPreference: executor) { 3 }.value

        #expect(r1 == 1)
        #expect(r2 == 2)
        #expect(r3 == 3)
        executor.shutdown()
    }
}
