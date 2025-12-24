//
//  IO.Blocking.Deadline Tests.swift
//  swift-io
//

import StandardsTestSupport
import Testing

@testable import IO_Blocking

extension IO.Blocking.Deadline {
    #TestSuites
}

// MARK: - Unit Tests

extension IO.Blocking.Deadline.Test.Unit {
    @Test("now returns current time")
    func nowReturnsCurrent() {
        let before = IO.Blocking.Deadline.now
        let after = IO.Blocking.Deadline.now
        #expect(after >= before)
    }

    @Test("after nanoseconds creates future deadline")
    func afterNanoseconds() {
        let now = IO.Blocking.Deadline.now
        let deadline = IO.Blocking.Deadline.after(nanoseconds: 1_000_000_000)
        #expect(deadline > now)
    }

    @Test("after milliseconds creates future deadline")
    func afterMilliseconds() {
        let now = IO.Blocking.Deadline.now
        let deadline = IO.Blocking.Deadline.after(milliseconds: 1000)
        #expect(deadline > now)
    }

    @Test("hasExpired returns false for future deadline")
    func hasExpiredFuture() {
        let deadline = IO.Blocking.Deadline.after(milliseconds: 10000)
        #expect(deadline.hasExpired == false)
    }

    @Test("remainingNanoseconds positive for future deadline")
    func remainingNanosecondsFuture() {
        let deadline = IO.Blocking.Deadline.after(milliseconds: 1000)
        #expect(deadline.remainingNanoseconds > 0)
    }
}

// MARK: - Edge Cases

extension IO.Blocking.Deadline.Test.EdgeCase {
    @Test("after zero nanoseconds")
    func afterZeroNanoseconds() {
        let now = IO.Blocking.Deadline.now
        let deadline = IO.Blocking.Deadline.after(nanoseconds: 0)
        // Deadline should be approximately now
        #expect(deadline >= now || deadline.hasExpired)
    }

    @Test("remainingNanoseconds zero for expired deadline")
    func remainingNanosecondsExpired() {
        // Create a deadline in the past
        let deadline = IO.Blocking.Deadline.after(nanoseconds: -1_000_000)
        #expect(deadline.remainingNanoseconds == 0)
    }
}
