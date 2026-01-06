//
//  IO.Blocking.Threads+Testing.swift
//  swift-io
//
//  Test support utilities for IO.Blocking.Threads.
//  Uses the #if IO_TESTING API exposed by the product module.
//

public import IO_Blocking_Threads

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// MARK: - Barrier

/// A barrier for synchronizing worker threads in tests.
/// All workers wait until the target count arrives, then all proceed together.
public final class Barrier: @unchecked Sendable {
    private var arrived: Int = 0
    private let target: Int
    private var released: Bool = false
    private var mutex = pthread_mutex_t()
    private var cond = pthread_cond_t()

    public init(count: Int) {
        self.target = count
        pthread_mutex_init(&mutex, nil)
        pthread_cond_init(&cond, nil)
    }

    deinit {
        pthread_mutex_destroy(&mutex)
        pthread_cond_destroy(&cond)
    }

    /// Called by each worker. Blocks until all workers arrive or timeout.
    /// Returns true if all workers arrived, false on timeout.
    public func arriveAndWait(timeout: Duration = .seconds(5)) -> Bool {
        pthread_mutex_lock(&mutex)

        arrived += 1
        let myArrival = arrived

        if myArrival >= target {
            // Last to arrive - release everyone
            released = true
            pthread_cond_broadcast(&cond)
            pthread_mutex_unlock(&mutex)
            return true
        }

        // Convert Duration to timespec for pthread_cond_timedwait
        let (seconds, attoseconds) = timeout.components
        let nanoseconds = attoseconds / 1_000_000_000

        var ts = timespec()
        var tv = timeval()
        gettimeofday(&tv, nil)
        ts.tv_sec = tv.tv_sec + Int(seconds)
        ts.tv_nsec = Int(tv.tv_usec) * 1000 + Int(nanoseconds)
        if ts.tv_nsec >= 1_000_000_000 {
            ts.tv_sec += 1
            ts.tv_nsec -= 1_000_000_000
        }

        while !released {
            let result = pthread_cond_timedwait(&cond, &mutex, &ts)
            if result == ETIMEDOUT {
                pthread_mutex_unlock(&mutex)
                return false
            }
        }

        pthread_mutex_unlock(&mutex)
        return true
    }

    /// Current count of workers that have arrived.
    public var arrivedCount: Int {
        pthread_mutex_lock(&mutex)
        defer { pthread_mutex_unlock(&mutex) }
        return arrived
    }
}

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
