//
//  IO.Blocking.Deadline.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 24/12/2025.
//

public import Clocks
public import StandardTime

extension IO.Blocking {
    /// A deadline for lane acceptance.
    ///
    /// Deadlines bound the time a caller waits for queue capacity or acceptance.
    /// They do not interrupt syscalls once executing.
    ///
    /// This is a typealias for `Time.Clock.Suspending.Instant`, providing
    /// a Foundation-free monotonic clock that pauses during system sleep.
    ///
    /// ## Clock Selection
    /// - **Darwin**: Uses `CLOCK_UPTIME_RAW`
    /// - **Linux**: Uses `CLOCK_MONOTONIC`
    /// - **Windows**: Uses `QueryUnbiasedInterruptTime`
    public typealias Deadline = Time.Clock.Suspending.Instant
}

// MARK: - Deadline Helpers

extension IO.Blocking.Deadline {
    /// The suspending clock instance for time measurements.
    private static var clock: Time.Clock.Suspending { Time.Clock.Suspending() }

    /// The current monotonic time.
    public static var now: Self {
        clock.now
    }

    /// Creates a deadline relative to now.
    ///
    /// - Parameter nanoseconds: Duration from now in nanoseconds.
    /// - Returns: A deadline at `now + nanoseconds`.
    public static func after(nanoseconds: Int64) -> Self {
        let current = now
        // Use truncating to avoid throws on Duration arithmetic
        return (try? current.advancing(truncating: .nanoseconds(nanoseconds))) ?? current
    }

    /// Creates a deadline relative to now.
    ///
    /// - Parameter milliseconds: Duration from now in milliseconds.
    /// - Returns: A deadline at `now + milliseconds`.
    public static func after(milliseconds: Int64) -> Self {
        after(nanoseconds: milliseconds * 1_000_000)
    }

    /// Whether this deadline has passed.
    public var hasExpired: Bool {
        Self.now >= self
    }

    /// Nanoseconds remaining until deadline, or 0 if expired.
    public var remainingNanoseconds: Int64 {
        let current = Self.now
        if current >= self {
            return 0
        }
        // duration(to:) returns Duration
        let d = current.duration(to: self)
        let c = d.components
        return c.seconds * 1_000_000_000 + Int64(c.attoseconds / 1_000_000_000)
    }
}
