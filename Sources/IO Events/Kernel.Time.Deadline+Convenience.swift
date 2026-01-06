// ===----------------------------------------------------------------------===//
//
// This source file is part of the swift-io open source project
//
// Copyright (c) 2025 Coen ten Thije Boonkkamp and the swift-io project authors
// Licensed under Apache License v2.0
//
// See LICENSE for license information
//
// ===----------------------------------------------------------------------===//

public import Kernel

extension Kernel.Time.Deadline {
    /// Whether this deadline has expired.
    ///
    /// Compares against the current monotonic time.
    @inlinable
    public var hasExpired: Bool {
        Self.now >= self
    }

    /// Nanoseconds remaining until this deadline.
    ///
    /// Returns 0 if the deadline has already expired.
    @inlinable
    public var remainingNanoseconds: Int64 {
        let now = Self.now.nanoseconds
        return nanoseconds > now ? Int64(nanoseconds - now) : 0
    }

    /// Remaining time as a Duration.
    ///
    /// Returns `.zero` if the deadline has already expired.
    @inlinable
    public var remaining: Duration {
        .nanoseconds(remainingNanoseconds)
    }
}
