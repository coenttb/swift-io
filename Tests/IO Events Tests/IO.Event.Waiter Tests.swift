//
//  IO.Event.Waiter Tests.swift
//  swift-io
//

import StandardsTestSupport
import Testing

@testable import IO_Events

extension IO.Event.Waiter {
    #TestSuites
}

// MARK: - Unit Tests

extension IO.Event.Waiter.Test.Unit {
    @Test("can create unarmed waiter")
    func canCreateUnarmed() async {
        let id = IO.Event.ID(raw: 42)
        let waiter = IO.Event.Waiter(id: id)
        #expect(waiter.id == id)
        #expect(!waiter.isArmed)
        #expect(!waiter.wasCancelled)
        #expect(!waiter.isDrained)
    }

    @Test("arm binds continuation")
    func armBindsContinuation() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Result<IO.Event, IO.Event.Failure>, Never>) in
            let waiter = IO.Event.Waiter(id: IO.Event.ID(raw: 1))
            #expect(!waiter.isArmed)
            #expect(waiter.arm(continuation: continuation) == true)
            #expect(waiter.isArmed)
            // Drain to avoid leak
            if let result = waiter.take.forResume() {
                result.continuation.resume(returning: .failure(.cancelled))
            }
        }
    }

    @Test("cancel marks waiter as cancelled")
    func cancelMarksWaiter() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Result<IO.Event, IO.Event.Failure>, Never>) in
            let waiter = IO.Event.Waiter(id: IO.Event.ID(raw: 1))
            waiter.arm(continuation: continuation)
            #expect(waiter.cancel() == true)
            #expect(waiter.wasCancelled == true)
            // Drain to avoid leak
            if let result = waiter.take.forResume() {
                result.continuation.resume(returning: .failure(.cancelled))
            }
        }
    }

    @Test("takeForResume returns continuation")
    func takeForResumeReturnsContinuation() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Result<IO.Event, IO.Event.Failure>, Never>) in
            let waiter = IO.Event.Waiter(id: IO.Event.ID(raw: 1))
            waiter.arm(continuation: continuation)
            if let result = waiter.take.forResume() {
                #expect(!result.wasCancelled)
                result.continuation.resume(returning: .failure(.cancelled))
            } else {
                Issue.record("takeForResume should return continuation")
            }
        }
    }

    @Test("takeForResume on cancelled waiter indicates cancelled")
    func takeForResumeCancelled() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Result<IO.Event, IO.Event.Failure>, Never>) in
            let waiter = IO.Event.Waiter(id: IO.Event.ID(raw: 1))
            waiter.arm(continuation: continuation)
            waiter.cancel()
            if let result = waiter.take.forResume() {
                #expect(result.wasCancelled == true)
                result.continuation.resume(returning: .failure(.cancelled))
            } else {
                Issue.record("takeForResume should return continuation even if cancelled")
            }
        }
    }
}

// MARK: - Edge Cases

extension IO.Event.Waiter.Test.EdgeCase {
    @Test("cancel before arm is handled correctly")
    func cancelBeforeArm() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Result<IO.Event, IO.Event.Failure>, Never>) in
            let waiter = IO.Event.Waiter(id: IO.Event.ID(raw: 1))
            // Cancel before arming
            #expect(waiter.cancel() == true)
            #expect(waiter.wasCancelled == true)
            #expect(!waiter.isArmed)
            // Now arm - should still work
            #expect(waiter.arm(continuation: continuation) == true)
            #expect(waiter.isArmed)
            // Drain - should indicate cancelled
            if let result = waiter.take.forResume() {
                #expect(result.wasCancelled == true)
                result.continuation.resume(returning: .failure(.cancelled))
            } else {
                Issue.record("takeForResume should return continuation")
            }
        }
    }

    @Test("double cancel is idempotent")
    func doubleCancelIdempotent() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Result<IO.Event, IO.Event.Failure>, Never>) in
            let waiter = IO.Event.Waiter(id: IO.Event.ID(raw: 1))
            waiter.arm(continuation: continuation)
            #expect(waiter.cancel() == true)  // First cancel succeeds
            #expect(waiter.cancel() == false) // Second cancel fails (already cancelled)
            #expect(waiter.wasCancelled == true)
            // Drain
            if let result = waiter.take.forResume() {
                result.continuation.resume(returning: .failure(.cancelled))
            }
        }
    }

    @Test("arm twice returns false")
    func armTwiceReturnsFalse() async {
        // Create two waiters and use one to test double-arm attempt
        let waiter = IO.Event.Waiter(id: IO.Event.ID(raw: 1))

        // First continuation - arm succeeds
        let _: Result<IO.Event, IO.Event.Failure> = await withCheckedContinuation { first in
            #expect(waiter.arm(continuation: first) == true)
            #expect(waiter.isArmed)

            // Drain immediately to resume
            if let result = waiter.take.forResume() {
                result.continuation.resume(returning: .failure(.cancelled))
            }
        }

        // After drain, state is drained - arm should fail
        #expect(waiter.isDrained)

        // Try to arm again with a new continuation - should fail
        let _: Result<IO.Event, IO.Event.Failure> = await withCheckedContinuation { second in
            // Second arm should fail - already drained
            #expect(waiter.arm(continuation: second) == false)

            // State should still be drained
            #expect(waiter.isDrained)

            // Resume second continuation manually (it was never bound)
            second.resume(returning: .failure(.cancelled))
        }
    }

    @Test("takeForResume twice returns nil second time")
    func takeForResumeTwice() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Result<IO.Event, IO.Event.Failure>, Never>) in
            let waiter = IO.Event.Waiter(id: IO.Event.ID(raw: 1))
            waiter.arm(continuation: continuation)
            let first = waiter.take.forResume()
            #expect(first != nil)
            let second = waiter.take.forResume()
            #expect(second == nil)
            #expect(waiter.isDrained == true)
            first?.continuation.resume(returning: .failure(.cancelled))
        }
    }

    @Test("takeForResume on unarmed waiter returns nil")
    func takeForResumeUnarmed() async {
        let waiter = IO.Event.Waiter(id: IO.Event.ID(raw: 1))
        #expect(waiter.take.forResume() == nil)
        #expect(!waiter.isDrained) // Should not mark as drained
    }

    @Test("cancel after drain fails")
    func cancelAfterDrain() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Result<IO.Event, IO.Event.Failure>, Never>) in
            let waiter = IO.Event.Waiter(id: IO.Event.ID(raw: 1))
            waiter.arm(continuation: continuation)
            if let result = waiter.take.forResume() {
                result.continuation.resume(returning: .failure(.cancelled))
            }
            #expect(waiter.cancel() == false) // Already drained
        }
    }
}

// MARK: - Invariants

extension IO.Event.Waiter.Test {
    @Suite struct Invariants {}
}

extension IO.Event.Waiter.Test.Invariants {
    @Test("cancel does NOT resume continuation")
    func cancelDoesNotResume() async {
        // This test verifies the invariant that cancel() only flips a bit,
        // it does NOT resume the continuation. The actor must call takeForResume().
        var resumed = false

        await withCheckedContinuation { (continuation: CheckedContinuation<Result<IO.Event, IO.Event.Failure>, Never>) in
            let waiter = IO.Event.Waiter(id: IO.Event.ID(raw: 1))
            waiter.arm(continuation: continuation)

            // Cancel synchronously - should NOT resume
            waiter.cancel()

            // If cancel() resumed, resumed would be set by now
            // But it shouldn't be, because we need to drain manually

            // Now drain properly
            if let result = waiter.take.forResume() {
                resumed = true
                result.continuation.resume(returning: .failure(.cancelled))
            }
        }

        #expect(resumed == true, "takeForResume must be called to resume")
    }

    @Test("cancel-before-arm preserves cancellation")
    func cancelBeforeArmPreservesCancellation() async {
        var wasCancelledOnDrain = false

        await withCheckedContinuation { (continuation: CheckedContinuation<Result<IO.Event, IO.Event.Failure>, Never>) in
            let waiter = IO.Event.Waiter(id: IO.Event.ID(raw: 1))

            // Cancel BEFORE arming (simulates fast onCancel race)
            waiter.cancel()

            // Then arm (simulates continuation being set)
            waiter.arm(continuation: continuation)

            // Drain should show cancelled
            if let result = waiter.take.forResume() {
                wasCancelledOnDrain = result.wasCancelled
                result.continuation.resume(returning: .failure(.cancelled))
            }
        }

        #expect(wasCancelledOnDrain == true, "cancel-before-arm must preserve cancellation")
    }

    @Test("typed Result continuation eliminates existential errors")
    func typedResultContinuation() async {
        // This test documents the design: Result<Event, Failure> continuation
        // means all error handling is typed, with no any Error casts.
        let result: Result<IO.Event, IO.Event.Failure> = await withCheckedContinuation { continuation in
            let waiter = IO.Event.Waiter(id: IO.Event.ID(raw: 1))
            waiter.arm(continuation: continuation)

            // Simulate actor drain with typed failure
            if let (cont, _) = waiter.take.forResume() {
                cont.resume(returning: .failure(.cancelled))
            }
        }

        // Verify typed switch works without casts
        switch result {
        case .success:
            Issue.record("Expected failure")
        case .failure(.cancelled):
            // Expected - typed pattern match works
            break
        case .failure:
            Issue.record("Expected .cancelled failure")
        }
    }
}
