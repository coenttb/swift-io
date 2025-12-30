//
//  IO.File.Lock.Acquire.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 30/12/2025.
//

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif os(Windows)
import WinSDK
#endif

extension IO.File.Lock {
    /// Acquisition mode for file locking operations.
    ///
    /// Controls how the lock acquisition behaves when the lock is held by another process.
    ///
    /// ## Modes
    ///
    /// - `.try`: Non-blocking. Returns immediately with `.wouldBlock` if the lock is held.
    /// - `.wait`: Blocking. Waits indefinitely until the lock is acquired or cancelled.
    /// - `.deadline(_:)`: Bounded wait. Waits until the deadline, then returns `.timedOut`.
    ///
    /// ## Example
    ///
    /// ```swift
    /// // Non-blocking attempt
    /// let token = try IO.File.Lock.Token(descriptor: fd, mode: .exclusive, acquire: .try)
    ///
    /// // Wait with timeout
    /// let deadline = ContinuousClock.Instant.now + .seconds(5)
    /// let token = try IO.File.Lock.Token(descriptor: fd, mode: .exclusive, acquire: .deadline(deadline))
    /// ```
    public enum Acquire: Sendable, Equatable {
        /// Non-blocking acquisition.
        ///
        /// Returns immediately. If the lock is held by another process,
        /// throws `IO.File.Lock.Error.wouldBlock`.
        case `try`

        /// Blocking acquisition with unbounded wait.
        ///
        /// Waits indefinitely until the lock is acquired.
        /// In async contexts, respects task cancellation.
        case wait

        /// Bounded wait with deadline.
        ///
        /// Attempts to acquire the lock until the specified instant.
        /// If the deadline passes without acquiring the lock, throws
        /// `IO.File.Lock.Error.timedOut`.
        ///
        /// - Note: This is best-effort. The actual wait time may slightly
        ///   exceed the deadline due to OS scheduling, but the function
        ///   will never return success after the deadline without having
        ///   acquired the lock.
        case deadline(Deadline)

        /// The deadline type for bounded waits.
        ///
        /// Uses `ContinuousClock.Instant` for monotonic, suspension-aware timing.
        public typealias Deadline = ContinuousClock.Instant
    }
}

// MARK: - Convenience Initializers

extension IO.File.Lock.Acquire {
    /// Creates a deadline from a duration from now.
    ///
    /// ```swift
    /// let acquire: IO.File.Lock.Acquire = .timeout(.seconds(5))
    /// ```
    public static func timeout(_ duration: Duration) -> Self {
        .deadline(.now + duration)
    }
}

// MARK: - Internal Helpers

extension IO.File.Lock.Acquire {
    /// Whether this mode is non-blocking (should use F_SETLK vs F_SETLKW).
    package var isNonBlocking: Bool {
        switch self {
        case .try:
            return true
        case .wait, .deadline:
            return false
        }
    }

    /// Whether this mode has a deadline.
    package var hasDeadline: Bool {
        if case .deadline = self {
            return true
        }
        return false
    }

    /// The deadline instant, if any.
    package var deadlineInstant: Deadline? {
        if case .deadline(let instant) = self {
            return instant
        }
        return nil
    }

    /// Checks if the deadline has passed.
    package func isExpired() -> Bool {
        guard let deadline = deadlineInstant else {
            return false
        }
        return ContinuousClock.Instant.now >= deadline
    }

    /// Time remaining until deadline, or nil if no deadline.
    package func remainingTime() -> Duration? {
        guard let deadline = deadlineInstant else {
            return nil
        }
        let now = ContinuousClock.Instant.now
        if now >= deadline {
            return .zero
        }
        return deadline - now
    }
}
