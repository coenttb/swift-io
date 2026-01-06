//
//  IO.Blocking.Threads+Testing.swift
//  swift-io
//
//  Test support utilities for IO.Blocking.Threads.
//  Uses the #if IO_TESTING API exposed by the product module.
//

public import IO_Blocking_Threads
@_exported public import Kernel_Test_Support
public import Kernel

// MARK: - Barrier

/// Re-export Kernel.Thread.Barrier for test convenience.
public typealias Barrier = Kernel.Thread.Barrier

// MARK: - ThreadPoolTesting

/// Test support utilities for IO.Blocking.Threads.
public enum ThreadPoolTesting {
    /// Waits until all workers are sleeping and the queue is empty.
    /// Returns true if idle state was reached, false on timeout.
    public static func waitUntilIdle(
        _ threads: IO.Blocking.Threads,
        workers expectedWorkers: Int,
        timeout: Duration = .seconds(5)
    ) async -> Bool {
        let interval: Duration = .milliseconds(50)
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            let snapshot = threads.debugSnapshot()
            if snapshot.sleepers == expectedWorkers && snapshot.queueIsEmpty {
                return true
            }
            try? await Task.sleep(for: interval)
        }
        return false
    }
}

// MARK: - Synchronous Queue State (Test Support)

extension IO.Blocking.Threads {
    /// Result of a synchronous try-submit operation.
    /// Used for benchmarking rejection latency without async overhead.
    public enum TrySubmitResult: Sendable {
        case wouldAccept      // Queue has capacity (would be accepted)
        case queueFull        // Queue is full (failFast would reject)
        case shutdown         // Lane is shutdown
    }

    /// Synchronously checks if a submission would be accepted or rejected.
    ///
    /// This is a **test-only** API for measuring rejection latency without
    /// the overhead of `withTaskCancellationHandler` + `withCheckedContinuation`.
    ///
    /// **Important**: This does NOT actually submit work. It only checks capacity.
    ///
    /// - Returns: What would happen if `run()` were called right now.
    public func trySubmitCheck() -> TrySubmitResult {
        let snapshot = debugSnapshot()

        if snapshot.isShutdown {
            return .shutdown
        }

        // For failFast: queue count == limit means rejection
        // For wait: would block (but we report wouldAccept since it wouldn't reject)
        // The debugSnapshot gives us queueCount which we can compare to the limit
        //
        // Note: This is an approximation since we can't access the internal limit
        // directly. For precise measurement, we'd need the lane to expose isFull.
        //
        // Heuristic: if queue is not empty and workers are all busy, likely full
        if !snapshot.queueIsEmpty {
            // Queue has items - for a minimal queueLimit (1), this means full
            return .queueFull
        }

        return .wouldAccept
    }
}

// MARK: - Lane Extension for Benchmarking

extension IO.Blocking.Lane {
    /// Result of checking queue capacity.
    public enum CapacityCheck: Sendable {
        case hasCapacity
        case wouldReject(IO.Lifecycle.Error<IO.Blocking.Lane.Error>)
    }

    /// Attempts to run with zero deadline (immediate rejection).
    ///
    /// This is useful for benchmarking rejection latency with minimal
    /// timeout overhead. With a zero deadline, the lane should reject
    /// immediately if the queue is full, without waiting.
    ///
    /// - Returns: The result, or throws `.failure(.queueFull)`/`.timeout` immediately.
    public func runImmediate<T: Sendable>(
        _ operation: @Sendable @escaping () -> T
    ) async throws(IO.Lifecycle.Error<IO.Blocking.Lane.Error>) -> T {
        // Use the smallest possible deadline - essentially "now"
        try await run(deadline: IO.Blocking.Deadline.now, operation)
    }
}
