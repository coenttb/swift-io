//
//  BoundedNIOFixture.swift
//  swift-io
//
//  NIO thread pool with external backpressure for fair benchmarking.
//  This matches swift-io's bounded queue semantics.
//

import Atomics
import NIOCore
import NIOPosix

/// Error thrown when bounded pool rejects due to capacity.
struct BoundedPoolOverloadError: Error, Sendable {}

/// NIO thread pool with external backpressure gate (failFast only).
///
/// Uses lock-free atomic for minimal overhead.
/// Enables fair comparison with swift-io's bounded lanes.
///
/// - Note: This is a benchmark fixture, not production code.
///   Wait policy is deferred (requires cancellation-correct gating).
final class BoundedNIOThreadPool: @unchecked Sendable {

    private let pool: NIOThreadPool
    private let limit: Int
    private let inFlight: ManagedAtomic<Int>

    init(pool: NIOThreadPool, limit: Int) {
        self.pool = pool
        self.limit = limit
        self.inFlight = ManagedAtomic(0)
    }

    /// Run work with failFast backpressure.
    /// Rejects immediately if at capacity.
    func runFailFast<T: Sendable>(
        _ work: @Sendable @escaping () throws -> T
    ) async throws -> T {
        // Try to acquire permit (CAS loop)
        while true {
            let current = inFlight.load(ordering: .acquiring)
            if current >= limit {
                throw BoundedPoolOverloadError()
            }
            if inFlight.compareExchange(
                expected: current,
                desired: current + 1,
                ordering: .acquiringAndReleasing
            ).exchanged {
                break
            }
        }

        // Execute work with guaranteed release
        do {
            let result = try await pool.runIfActive(work)
            inFlight.wrappingDecrement(ordering: .releasing)
            return result
        } catch {
            inFlight.wrappingDecrement(ordering: .releasing)
            throw error
        }
    }

    /// Current in-flight count (for testing/debugging).
    var currentInFlight: Int {
        inFlight.load(ordering: .relaxed)
    }
}
