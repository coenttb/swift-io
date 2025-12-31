//
//  IO.Completion.Queue Tests.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 31/12/2025.
//

import StandardsTestSupport
import Testing

@testable import IO_Completions

extension IO.Completion.Queue {
    #TestSuites
}

// MARK: - Waiter Unit Tests

/// Tests for the Waiter state machine, which is the core of the
/// precondition(armed) fix.
extension IO.Completion.Waiter {
    #TestSuites
}

extension IO.Completion.Waiter.Test.Unit {
    @Test("cancel before arm returns false from arm()")
    func cancelBeforeArmReturnsFalse() async {
        // This tests the core fix: arm() returning false when
        // cancellation happens before arm is called.
        let id = IO.Completion.ID(raw: 1)
        let waiter = IO.Completion.Waiter(id: id)

        // Cancel BEFORE arming
        waiter.cancel()
        #expect(waiter.wasCancelled)

        // Now arm - should return false (not crash!)
        await withCheckedContinuation { (c: CheckedContinuation<IO.Completion.ID, Never>) in
            let armed = waiter.arm(continuation: c)
            #expect(!armed, "arm() should return false when cancelled before arm")
            #expect(waiter.isArmed, "waiter should still be armed (in armedCancelled state)")
            #expect(waiter.wasCancelled, "cancellation should be preserved")

            // Resume to avoid leak
            waiter.resume.id(id)
        }
    }

    @Test("cancel after arm marks waiter as cancelled")
    func cancelAfterArm() async {
        let id = IO.Completion.ID(raw: 1)
        let waiter = IO.Completion.Waiter(id: id)

        await withCheckedContinuation { (c: CheckedContinuation<IO.Completion.ID, Never>) in
            let armed = waiter.arm(continuation: c)
            #expect(armed, "arm() should succeed")
            #expect(waiter.isArmed)
            #expect(!waiter.wasCancelled)

            // Cancel AFTER arming
            waiter.cancel()
            #expect(waiter.wasCancelled)

            // Resume
            waiter.resume.id(id)
        }
    }

    @Test("takeForResume indicates cancelled state")
    func takeForResumeIndicatesCancelled() async {
        let id = IO.Completion.ID(raw: 1)
        let waiter = IO.Completion.Waiter(id: id)

        await withCheckedContinuation { (c: CheckedContinuation<IO.Completion.ID, Never>) in
            waiter.arm(continuation: c)
            waiter.cancel()

            if let result = waiter.take.forResume() {
                #expect(result.cancelled, "takeForResume should indicate cancelled")
                result.continuation.resume(returning: id)
            } else {
                Issue.record("takeForResume should return continuation")
            }
        }
    }

    @Test("double resume returns false on second call")
    func doubleResumeReturnsFalse() async {
        // Tests the exactly-once invariant
        let id = IO.Completion.ID(raw: 1)
        let waiter = IO.Completion.Waiter(id: id)

        await withCheckedContinuation { (c: CheckedContinuation<IO.Completion.ID, Never>) in
            waiter.arm(continuation: c)

            // First resume should succeed
            let first = waiter.resume.id(id)
            #expect(first, "first resume should succeed")

            // Second resume should fail (already drained)
            let second = waiter.resume.id(id)
            #expect(!second, "second resume should fail")
        }
    }

    @Test("takeForResume on unarmed waiter returns nil")
    func takeForResumeOnUnarmed() async {
        let id = IO.Completion.ID(raw: 1)
        let waiter = IO.Completion.Waiter(id: id)

        // Not armed yet
        let result = waiter.take.forResume()
        #expect(result == nil, "takeForResume should return nil when not armed")
    }

    @Test("takeForResume on cancelled-unarmed returns nil")
    func takeForResumeOnCancelledUnarmed() async {
        let id = IO.Completion.ID(raw: 1)
        let waiter = IO.Completion.Waiter(id: id)

        // Cancel before arm
        waiter.cancel()

        // Not armed yet - takeForResume should return nil
        let result = waiter.take.forResume()
        #expect(result == nil, "takeForResume should return nil when cancelled but not armed")
    }
}

// MARK: - Edge Cases

extension IO.Completion.Waiter.Test.EdgeCase {
    @Test("cancel-before-arm then takeForResume indicates cancelled")
    func cancelBeforeArmThenTakeForResume() async {
        // This is the key scenario that was crashing before the fix
        let id = IO.Completion.ID(raw: 1)
        let waiter = IO.Completion.Waiter(id: id)

        // Cancel BEFORE arm (simulates fast onCancel race)
        waiter.cancel()
        #expect(waiter.wasCancelled)

        await withCheckedContinuation { (c: CheckedContinuation<IO.Completion.ID, Never>) in
            // Arm returns false but stores continuation
            let armed = waiter.arm(continuation: c)
            #expect(!armed)

            // takeForResume should still work and indicate cancelled
            if let result = waiter.take.forResume() {
                #expect(result.cancelled, "should indicate cancelled")
                result.continuation.resume(returning: id)
            } else {
                Issue.record("takeForResume should return continuation even after cancel-before-arm")
            }
        }
    }

    @Test("multiple cancels are idempotent")
    func multipleCancelsIdempotent() async {
        let id = IO.Completion.ID(raw: 1)
        let waiter = IO.Completion.Waiter(id: id)

        await withCheckedContinuation { (c: CheckedContinuation<IO.Completion.ID, Never>) in
            waiter.arm(continuation: c)

            // Cancel multiple times - should not crash
            waiter.cancel()
            waiter.cancel()
            waiter.cancel()

            #expect(waiter.wasCancelled)

            // Resume
            waiter.resume.id(id)
        }
    }

    @Test("cancel after drain is no-op")
    func cancelAfterDrain() async {
        let id = IO.Completion.ID(raw: 1)
        let waiter = IO.Completion.Waiter(id: id)

        await withCheckedContinuation { (c: CheckedContinuation<IO.Completion.ID, Never>) in
            waiter.arm(continuation: c)

            // Drain first
            if let result = waiter.take.forResume() {
                result.continuation.resume(returning: id)
            }

            // Cancel after drain - should not crash
            waiter.cancel()

            // State should still be drained (not cancelledDrained)
            // since cancel happened after drain completed
        }
    }
}

// MARK: - Invariants

extension IO.Completion.Waiter.Test {
    @Suite struct Invariants {}
}

extension IO.Completion.Waiter.Test.Invariants {
    @Test("cancel does NOT resume continuation")
    func cancelDoesNotResume() async {
        // This test verifies that cancel() only flips a bit,
        // it does NOT resume the continuation. The queue must call
        // takeForResume() to get the continuation.
        var resumed = false

        await withCheckedContinuation { (c: CheckedContinuation<IO.Completion.ID, Never>) in
            let waiter = IO.Completion.Waiter(id: IO.Completion.ID(raw: 1))
            waiter.arm(continuation: c)

            // Cancel synchronously - should NOT resume
            waiter.cancel()

            // If cancel() resumed, we'd never get here
            // Now drain properly
            if let result = waiter.take.forResume() {
                resumed = true
                result.continuation.resume(returning: waiter.id)
            }
        }

        #expect(resumed, "takeForResume must be called to resume")
    }

    @Test("single resumption funnel - only takeForResume provides continuation")
    func singleResumptionFunnel() async {
        // Verifies the invariant: continuation is only available via takeForResume
        let id = IO.Completion.ID(raw: 1)
        let waiter = IO.Completion.Waiter(id: id)

        await withCheckedContinuation { (c: CheckedContinuation<IO.Completion.ID, Never>) in
            waiter.arm(continuation: c)

            // First take succeeds
            let first = waiter.take.forResume()
            #expect(first != nil)

            // Second take returns nil (already drained)
            let second = waiter.take.forResume()
            #expect(second == nil)

            // Resume the first
            first?.continuation.resume(returning: id)
        }
    }
}

// MARK: - Integration Tests

extension IO.Completion.Queue.Test {
    @Suite struct Integration {}
}

// MARK: - Test Helpers

extension IO.Completion.Driver.Fake {
    /// Waits until a submission with the given ID is recorded (async wrapper).
    ///
    /// Event-driven synchronization using condition variables.
    func waitUntilSubmitted(
        id: IO.Completion.ID,
        timeoutMs: UInt32 = 200
    ) async throws {
        // Run blocking wait on a detached task to avoid blocking cooperative pool
        let success = await Task.detached { [self] in
            self.waitForSubmission(id: id, timeoutMs: timeoutMs)
        }.value
        if !success {
            throw TestTimeoutError()
        }
    }

    /// Waits until all given IDs are submitted.
    func waitUntilAllSubmitted(
        ids: [IO.Completion.ID],
        timeoutMs: UInt32 = 500
    ) async throws {
        for id in ids {
            try await waitUntilSubmitted(id: id, timeoutMs: timeoutMs)
        }
    }
}

/// Error thrown when test synchronization times out.
struct TestTimeoutError: Error {}

extension IO.Completion.Queue.Test.Integration {
    @Test("queue creation and shutdown")
    func queueCreationAndShutdown() async throws {
        // Simple test: can we create a queue and shut it down?
        let fake = IO.Completion.Driver.Fake()
        let driver = IO.Completion.Driver(fake)

        let queue = try await IO.Completion.Queue(driver: driver)

        // Just shutdown immediately
        await queue.shutdown()

        // If we get here, basic lifecycle works
        #expect(true)
    }

    @Test("full pipeline: submit → poll thread → complete → resume")
    func fullPipeline() async throws {
        // This test proves the entire runtime works end-to-end:
        // 1. Queue.submit() pushes to Submission.Queue
        // 2. Poll thread drains and submits to driver
        // 3. Fake.complete() injects completion event
        // 4. Poll thread pushes to Bridge
        // 5. Queue drains Bridge and resumes waiter
        // 6. submit() returns with result

        let fake = IO.Completion.Driver.Fake()
        let driver = IO.Completion.Driver(fake)

        // Create queue - this spawns the poll thread
        let queue = try await IO.Completion.Queue(driver: driver)

        // Get an ID (Copyable - safe to pass across task boundary)
        let id = await queue.nextID()

        // Submit in a task - Operation created inside task (not captured across boundary)
        let resultTask = Task { () -> IO.Completion.Event in
            let operation = IO.Completion.Operation.nop(id: id)
            let result = try await queue.submit(operation)
            return result.take().event
        }

        // Wait until submission is recorded (event-driven, no sleep)
        try await fake.waitUntilSubmitted(id: id)

        // Verify submission was recorded
        #expect(fake.submissions[id] == .nop, "submission should be recorded by driver")

        // Inject completion
        fake.complete(id: id, kind: .nop, outcome: .success(.completed))

        // Await result
        let event = try await resultTask.value

        // Verify result
        #expect(event.id == id)
        #expect(event.kind == .nop)
        #expect(event.outcome == .success(.completed))

        // Shutdown cleanly
        await queue.shutdown()
    }

    @Test("cancellation before completion returns cancelled event (Pattern A)")
    func cancellationBeforeCompletion() async throws {
        let fake = IO.Completion.Driver.Fake()
        let driver = IO.Completion.Driver(fake)
        let queue = try await IO.Completion.Queue(driver: driver)

        let id = await queue.nextID()

        // Submit in a task - Operation created inside
        let resultTask = Task { () -> IO.Completion.Event in
            let operation = IO.Completion.Operation.nop(id: id)
            let result = try await queue.submit(operation)
            return result.take().event
        }

        // Wait until submission is in-flight
        try await fake.waitUntilSubmitted(id: id)

        // Cancel the task
        resultTask.cancel()

        // Pattern A: cancellation returns result with Outcome.cancelled, not CancellationError
        let event: IO.Completion.Event
        do {
            event = try await resultTask.value
        } catch is CancellationError {
            Issue.record("Task cancellation escaped; queue.submit must translate cancellation to Outcome.cancelled for Pattern A")
            throw CancellationError()
        }

        #expect(event.outcome == .cancelled, "cancelled task should get cancelled outcome")

        await queue.shutdown()
    }

    @Test("shutdown wakes pending operations with lifecycle error")
    func shutdownWakesPending() async throws {
        let fake = IO.Completion.Driver.Fake()
        let driver = IO.Completion.Driver(fake)
        let queue = try await IO.Completion.Queue(driver: driver)

        let id = await queue.nextID()

        // Submit in a task - Operation created inside
        let resultTask = Task { () -> IO.Completion.Event in
            let operation = IO.Completion.Operation.nop(id: id)
            let result = try await queue.submit(operation)
            return result.take().event
        }

        // Wait until submission is in-flight
        try await fake.waitUntilSubmitted(id: id)

        // Shutdown should wake the pending operation
        await queue.shutdown()

        // Shutdown throws lifecycle error (not Pattern A return)
        do {
            _ = try await resultTask.value
            Issue.record("expected lifecycle error from shutdown")
        } catch let error as IO.Lifecycle.Error<IO.Completion.Error> {
            // Expected - verify it's the right error
            if case .failure(let completionError) = error {
                #expect(completionError == .lifecycle(.shutdownInProgress),
                       "expected shutdownInProgress, got \(completionError)")
            }
        }
    }

    @Test("multiple concurrent submits complete correctly")
    func multipleConcurrentSubmits() async throws {
        let fake = IO.Completion.Driver.Fake()
        let driver = IO.Completion.Driver(fake)
        let queue = try await IO.Completion.Queue(driver: driver)

        let count = 10
        var ids: [IO.Completion.ID] = []

        // Get IDs (Copyable - safe to pass across task boundaries)
        for _ in 0..<count {
            ids.append(await queue.nextID())
        }

        // Submit all concurrently - each Operation created inside its Task
        let tasks = ids.map { id in
            Task { () -> IO.Completion.Event in
                let operation = IO.Completion.Operation.nop(id: id)
                let result = try await queue.submit(operation)
                return result.take().event
            }
        }

        // Wait until all submissions are recorded (event-driven, no sleep)
        try await fake.waitUntilAllSubmitted(ids: ids)

        // Complete all
        for id in ids {
            fake.complete(id: id, kind: .nop, outcome: .success(.bytes(Int(id.raw))))
        }

        // Collect results
        var successCount = 0
        for task in tasks {
            let event = try await task.value
            if case .success(let value) = event.outcome {
                if case .bytes(let n) = value {
                    successCount += 1
                    // Verify the result matches the ID
                    #expect(n == Int(event.id.raw))
                }
            }
        }

        #expect(successCount == count, "all \(count) operations should complete successfully")

        await queue.shutdown()
    }
}

// MARK: - Driver.Fake Tests

extension IO.Completion.Driver.Fake {
    #TestSuites
}

extension IO.Completion.Driver.Fake.Test.Unit {
    @Test("fake driver records submissions")
    func recordsSubmissions() async {
        let fake = IO.Completion.Driver.Fake()
        let driver = IO.Completion.Driver(fake)

        let handle = try! driver.create()
        let id = IO.Completion.ID(raw: 42)
        let operation = IO.Completion.Operation.nop(id: id)

        try! driver.submit(handle, operation: operation)

        #expect(fake.submissions[id] == .nop)
    }

    @Test("fake driver injects completions")
    func injectsCompletions() async {
        let fake = IO.Completion.Driver.Fake()
        let driver = IO.Completion.Driver(fake)

        let handle = try! driver.create()
        let id = IO.Completion.ID(raw: 42)

        // Inject a completion
        fake.complete(id: id, kind: .read, outcome: .success(.bytes(100)))

        // Poll should return it
        var buffer: [IO.Completion.Event] = []
        let count = try! driver.poll(handle, deadline: nil, into: &buffer)

        #expect(count == 1)
        #expect(buffer.count == 1)
        #expect(buffer[0].id == id)
        #expect(buffer[0].kind == .read)
        #expect(buffer[0].outcome == .success(.bytes(100)))
    }

    @Test("fake driver wakeup is recorded")
    func wakeupRecorded() async {
        let fake = IO.Completion.Driver.Fake()
        let driver = IO.Completion.Driver(fake)

        let handle = try! driver.create()
        let wakeup = try! driver.createWakeupChannel(handle)

        #expect(!fake.wasWoken)

        wakeup.wake()

        #expect(fake.wasWoken)
    }
}
