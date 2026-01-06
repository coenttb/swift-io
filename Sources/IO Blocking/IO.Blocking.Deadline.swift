//
//  IO.Blocking.Deadline.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 24/12/2025.
//

public import Clocks
public import StandardTime

// MARK: - Dependency Decision
//
// swift-io depends on swift-time-standard (Clocks/StandardTime) for monotonic time.
// This is a deliberate choice for ecosystem coherence across swift-standards packages.
// Deadline is a thin wrapper providing lane-specific convenience methods.

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
        now.advanced(by: .nanoseconds(nanoseconds))
    }

    /// Creates a deadline relative to now.
    ///
    /// - Parameter milliseconds: Duration from now in milliseconds.
    /// - Returns: A deadline at `now + milliseconds`.
    public static func after(milliseconds: Int64) -> Self {
        after(nanoseconds: milliseconds * 1_000_000)
    }

    /// Creates a deadline relative to now.
    ///
    /// - Parameter duration: Duration from now.
    /// - Returns: A deadline at `now + duration`.
    public static func after(_ duration: Swift.Duration) -> Self {
        let components = duration.components
        let nanoseconds = components.seconds * 1_000_000_000 + Int64(components.attoseconds / 1_000_000_000)
        return after(nanoseconds: nanoseconds)
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

    /// Nanoseconds elapsed since another instant (for latency tracking).
    ///
    /// - Parameter other: The earlier instant.
    /// - Returns: Nanoseconds elapsed, or 0 if `other` is in the future.
    public func nanosecondsSince(_ other: Self) -> UInt64 {
        if self <= other {
            return 0
        }
        let d = other.duration(to: self)
        let c = d.components
        // Duration is positive since self > other
        let ns = c.seconds * 1_000_000_000 + Int64(c.attoseconds / 1_000_000_000)
        return UInt64(ns)
    }
}
