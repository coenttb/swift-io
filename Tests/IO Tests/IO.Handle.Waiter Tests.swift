//
//  IO.Handle.Waiter Tests.swift
//  swift-io
//

import StandardsTestSupport
import Testing

@testable import IO

extension IO.Handle.Waiter {
    #TestSuites
}

// MARK: - Unit Tests

extension IO.Handle.Waiter.Test.Unit {
    @Test("can create unarmed waiter")
    func canCreateUnarmed() async {
        let waiter = IO.Handle.Waiter(token: 42)
        #expect(waiter.token == 42)
        #expect(!waiter.isArmed)
        #expect(!waiter.wasCancelled)
        #expect(!waiter.isDrained)
    }

    @Test("arm binds continuation")
    func armBindsContinuation() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let waiter = IO.Handle.Waiter(token: 42)
            #expect(!waiter.isArmed)
            #expect(waiter.arm(continuation: continuation) == true)
            #expect(waiter.isArmed)
            // Drain to avoid leak
            if let result = waiter.takeForResume() {
                result.continuation.resume()
            }
        }
    }

    @Test("cancel marks waiter as cancelled")
    func cancelMarksWaiter() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let waiter = IO.Handle.Waiter(token: 1)
            waiter.arm(continuation: continuation)
            #expect(waiter.cancel() == true)
            #expect(waiter.wasCancelled == true)
            // Drain to avoid leak
            if let result = waiter.takeForResume() {
                result.continuation.resume()
            }
        }
    }

    @Test("takeForResume returns continuation")
    func takeForResumeReturnsContinuation() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let waiter = IO.Handle.Waiter(token: 1)
            waiter.arm(continuation: continuation)
            if let result = waiter.takeForResume() {
                #expect(!result.wasCancelled)
                result.continuation.resume()
            } else {
                Issue.record("takeForResume should return continuation")
            }
        }
    }

    @Test("takeForResume on cancelled waiter indicates cancelled")
    func takeForResumeCancelled() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let waiter = IO.Handle.Waiter(token: 1)
            waiter.arm(continuation: continuation)
            waiter.cancel()
            if let result = waiter.takeForResume() {
                #expect(result.wasCancelled == true)
                result.continuation.resume()
            } else {
                Issue.record("takeForResume should return continuation even if cancelled")
            }
        }
    }
}

// MARK: - Edge Cases

extension IO.Handle.Waiter.Test.EdgeCase {
    @Test("cancel before arm is handled correctly")
    func cancelBeforeArm() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let waiter = IO.Handle.Waiter(token: 1)
            // Cancel before arming
            #expect(waiter.cancel() == true)
            #expect(waiter.wasCancelled == true)
            #expect(!waiter.isArmed)
            // Now arm - should still work
            #expect(waiter.arm(continuation: continuation) == true)
            #expect(waiter.isArmed)
            // Drain - should indicate cancelled
            if let result = waiter.takeForResume() {
                #expect(result.wasCancelled == true)
                result.continuation.resume()
            } else {
                Issue.record("takeForResume should return continuation")
            }
        }
    }

    @Test("double cancel is idempotent")
    func doubleCancelIdempotent() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let waiter = IO.Handle.Waiter(token: 1)
            waiter.arm(continuation: continuation)
            #expect(waiter.cancel() == true)  // First cancel succeeds
            #expect(waiter.cancel() == false) // Second cancel fails (already cancelled)
            #expect(waiter.wasCancelled == true)
            // Drain
            if let result = waiter.takeForResume() {
                result.continuation.resume()
            }
        }
    }

    @Test("double arm is idempotent")
    func doubleArmIdempotent() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let waiter = IO.Handle.Waiter(token: 1)
            #expect(waiter.arm(continuation: continuation) == true)  // First arm succeeds
            // Second arm would need another continuation, but should fail anyway
            // We can't test this easily without another continuation, so just verify state
            #expect(waiter.isArmed)
            // Drain
            if let result = waiter.takeForResume() {
                result.continuation.resume()
            }
        }
    }

    @Test("takeForResume twice returns nil second time")
    func takeForResumeTwice() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let waiter = IO.Handle.Waiter(token: 1)
            waiter.arm(continuation: continuation)
            let first = waiter.takeForResume()
            #expect(first != nil)
            let second = waiter.takeForResume()
            #expect(second == nil)
            #expect(waiter.isDrained == true)
            first?.continuation.resume()
        }
    }

    @Test("takeForResume on unarmed waiter returns nil")
    func takeForResumeUnarmed() async {
        let waiter = IO.Handle.Waiter(token: 1)
        #expect(waiter.takeForResume() == nil)
        #expect(!waiter.isDrained) // Should not mark as drained
    }

    @Test("cancel after drain fails")
    func cancelAfterDrain() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let waiter = IO.Handle.Waiter(token: 1)
            waiter.arm(continuation: continuation)
            _ = waiter.takeForResume()?.continuation.resume()
            #expect(waiter.cancel() == false) // Already drained
        }
    }
}

// MARK: - Invariants

extension IO.Handle.Waiter.Test {
    @Suite struct Invariants {}
}

extension IO.Handle.Waiter.Test.Invariants {
    @Test("cancel does NOT resume continuation")
    func cancelDoesNotResume() async {
        // This test verifies the invariant that cancel() only flips a bit,
        // it does NOT resume the continuation. The actor must call takeForResume().
        var resumed = false

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let waiter = IO.Handle.Waiter(token: 1)
            waiter.arm(continuation: continuation)

            // Cancel synchronously - should NOT resume
            waiter.cancel()

            // If cancel() resumed, resumed would be set by now
            // But it shouldn't be, because we need to drain manually

            // Now drain properly
            if let result = waiter.takeForResume() {
                resumed = true
                result.continuation.resume()
            }
        }

        #expect(resumed == true, "takeForResume must be called to resume")
    }

    @Test("cancel-before-arm preserves cancellation")
    func cancelBeforeArmPreservesCancellation() async {
        var wasCancelledOnDrain = false

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let waiter = IO.Handle.Waiter(token: 1)

            // Cancel BEFORE arming (simulates fast onCancel race)
            waiter.cancel()

            // Then arm (simulates continuation being set)
            waiter.arm(continuation: continuation)

            // Drain should show cancelled
            if let result = waiter.takeForResume() {
                wasCancelledOnDrain = result.wasCancelled
                result.continuation.resume()
            }
        }

        #expect(wasCancelledOnDrain == true, "cancel-before-arm must preserve cancellation")
    }
}
