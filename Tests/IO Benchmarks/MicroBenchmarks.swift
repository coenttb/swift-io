//
//  MicroBenchmarks.swift
//  swift-io
//
//  Isolation microbenchmarks measuring individual operation costs.
//
//  ## Category: Micro
//  These benchmarks isolate specific costs without confounding factors.
//  They run in tight loops with minimal setup to measure pure operation overhead.
//
//  ## What These Benchmarks Measure
//  - AdmissionCost: Queue insertion only (no work, no completion wait)
//  - WakeupCost: Signal → resume latency in isolation
//  - ActorHopCost: Round-trip actor hop with no work
//  - ErrorRepresentation: Typed vs existential error payloads
//
//  ## Running
//  swift test -c release --filter MicroBenchmarks
//

import Foundation
import IO
import NIOPosix
import StandardsTestSupport
import Testing

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

enum MicroBenchmarks {
    #TestSuites
}

// MARK: - Actor Hop Cost

extension MicroBenchmarks.Test.Performance {

    /// Measures pure actor hop overhead without any blocking work.
    ///
    /// This isolates the cost of:
    /// 1. Caller → Pool actor hop
    /// 2. Pool actor → Lane submission
    /// 3. Lane completion → Pool actor hop
    /// 4. Pool actor → Caller resume
    @Suite("Actor Hop Cost")
    struct ActorHop {

        @Test(
            "swift-io: actor hop round-trip (no work)",
            .timed(iterations: 2000, warmup: 200, trackAllocations: false)
        )
        func actorHopNoWork() async throws {
            // Use inline lane to eliminate thread dispatch - measuring only actor machinery
            let lane = IO.Blocking.Lane.inline
            let result: Result<Int, Never> = try await lane.run(deadline: .none) { 42 }
            switch result {
            case .success(let value):
                withExtendedLifetime(value) {}
            }
        }

        @Test(
            "swift-io: Pool actor method call (no work)",
            .timed(iterations: 1000, warmup: 100, trackAllocations: false)
        )
        func poolActorCall() async throws {
            let pool = IO.Executor.Pool<Int>(lane: .inline)

            // Register a handle
            let id = try await pool.register(1)

            // Measure transaction (actor hop + handle lookup)
            let value = try await pool.transaction(id) { value in
                value
            }
            withExtendedLifetime(value) {}

            // Cleanup
            try await pool.destroy(id)
            await pool.shutdown()
        }
    }
}

// MARK: - Admission Cost

extension MicroBenchmarks.Test.Performance {

    /// Measures queue admission cost in isolation.
    ///
    /// Uses failFast strategy with unfilled queue to measure pure enqueue cost
    /// without any waiting or contention.
    @Suite("Admission Cost")
    struct Admission {

        static let fixture = ThreadPoolFixture.shared

        @Test(
            "swift-io: queue admission (no contention)",
            .timed(iterations: 500, warmup: 50, trackAllocations: false)
        )
        func admissionNoContention() async throws {
            let lane = Self.fixture.swiftIOLane
            // Trivial work - measuring admission + completion path
            let result: Result<Int, Never> = try await lane.run(deadline: .none) { 1 }
            switch result {
            case .success(let value):
                withExtendedLifetime(value) {}
            }
        }

        @Test(
            "NIOThreadPool: queue admission (no contention)",
            .timed(iterations: 500, warmup: 50, trackAllocations: false)
        )
        func nioAdmissionNoContention() async throws {
            let result = try await Self.fixture.nio.runIfActive { 1 }
            withExtendedLifetime(result) {}
        }
    }
}

// MARK: - Wakeup Cost

extension MicroBenchmarks.Test.Performance {

    /// Measures signal → resume latency.
    ///
    /// This isolates the cost of pthread condition variable signaling
    /// and Swift continuation resumption.
    @Suite("Wakeup Cost")
    struct Wakeup {

        /// A minimal waiter using pthread primitives to measure raw wakeup cost.
        final class SignalWaiter: @unchecked Sendable {
            private var mutex = pthread_mutex_t()
            private var cond = pthread_cond_t()
            private var signaled = false

            init() {
                pthread_mutex_init(&mutex, nil)
                pthread_cond_init(&cond, nil)
            }

            deinit {
                pthread_cond_destroy(&cond)
                pthread_mutex_destroy(&mutex)
            }

            func wait() {
                pthread_mutex_lock(&mutex)
                while !signaled {
                    pthread_cond_wait(&cond, &mutex)
                }
                signaled = false  // Reset for reuse
                pthread_mutex_unlock(&mutex)
            }

            func signal() {
                pthread_mutex_lock(&mutex)
                signaled = true
                pthread_cond_signal(&cond)
                pthread_mutex_unlock(&mutex)
            }
        }

        @Test(
            "pthread: signal → wake latency",
            .timed(iterations: 1000, warmup: 100, trackAllocations: false)
        )
        func pthreadSignalWake() async throws {
            let waiter = SignalWaiter()

            // Spawn a thread that waits
            let thread = Thread {
                waiter.wait()
            }
            thread.start()

            // Small delay to ensure thread is waiting
            try await Task.sleep(for: .microseconds(100))

            // Signal and measure until thread completes
            waiter.signal()

            // Wait for thread to complete
            while !thread.isFinished {
                try await Task.sleep(for: .microseconds(10))
            }
        }
    }
}

// MARK: - Error Representation Cost

extension MicroBenchmarks.Test.Performance {

    /// Measures typed error vs existential error overhead.
    ///
    /// Compares:
    /// - Swift typed throws with concrete error type
    /// - Existential `any Error` boxing
    @Suite("Error Representation")
    struct ErrorRepresentation {

        struct SmallError: Error, Sendable {
            let code: Int
        }

        struct LargeError: Error, Sendable {
            let code: Int
            let message: String
            let context: [String: String]

            static func make() -> LargeError {
                LargeError(
                    code: 42,
                    message: "Something went wrong",
                    context: ["key1": "value1", "key2": "value2"]
                )
            }
        }

        static let fixture = ThreadPoolFixture.shared

        @Test(
            "swift-io: typed throw (small error)",
            .timed(iterations: 500, warmup: 50, trackAllocations: true)
        )
        func typedThrowSmall() async throws {
            let lane = Self.fixture.swiftIOLane
            let result: Result<Int, SmallError> = try await lane.run(deadline: .none) { () throws(SmallError) -> Int in
                throw SmallError(code: 42)
            }
            switch result {
            case .success:
                break
            case .failure(let error):
                withExtendedLifetime(error) {}
            }
        }

        @Test(
            "swift-io: typed throw (large error)",
            .timed(iterations: 500, warmup: 50, trackAllocations: true)
        )
        func typedThrowLarge() async throws {
            let lane = Self.fixture.swiftIOLane
            let result: Result<Int, LargeError> = try await lane.run(deadline: .none) { () throws(LargeError) -> Int in
                throw LargeError.make()
            }
            switch result {
            case .success:
                break
            case .failure(let error):
                withExtendedLifetime(error) {}
            }
        }

        @Test(
            "NIOThreadPool: existential throw (small error)",
            .timed(iterations: 500, warmup: 50, trackAllocations: true)
        )
        func existentialThrowSmall() async throws {
            do {
                _ = try await Self.fixture.nio.runIfActive {
                    throw SmallError(code: 42)
                }
            } catch {
                withExtendedLifetime(error) {}
            }
        }

        @Test(
            "NIOThreadPool: existential throw (large error)",
            .timed(iterations: 500, warmup: 50, trackAllocations: true)
        )
        func existentialThrowLarge() async throws {
            do {
                _ = try await Self.fixture.nio.runIfActive {
                    throw LargeError.make()
                }
            } catch {
                withExtendedLifetime(error) {}
            }
        }
    }
}

// MARK: - Completion Cost

extension MicroBenchmarks.Test.Performance {

    /// Measures completion-side dictionary operations under lock.
    ///
    /// This isolates the cost of:
    /// 1. Lock acquisition
    /// 2. Dictionary lookup/insert (completionWaiters, completions, abandonedTickets)
    /// 3. Lock release
    ///
    /// Compares:
    /// - Dictionary-based: current swift-io approach (lookup waiter by ticket)
    /// - Context-based: proposed approach (continuation bundled with job)
    @Suite("Completion Cost")
    struct Completion {

        /// Simulates the current two-stage completion path.
        final class DictionaryBasedState: @unchecked Sendable {
            private var mutex = pthread_mutex_t()
            private var completions: [UInt64: Int] = [:]
            private var waiters: [UInt64: Int] = [:]
            private var abandoned: Set<UInt64> = []

            init() {
                pthread_mutex_init(&mutex, nil)
                // Pre-size dictionaries to avoid allocation during benchmark
                completions.reserveCapacity(1000)
                waiters.reserveCapacity(1000)
            }

            deinit {
                pthread_mutex_destroy(&mutex)
            }

            /// Simulates waiter registration (caller side)
            func registerWaiter(ticket: UInt64, waiter: Int) {
                pthread_mutex_lock(&mutex)
                // Check if completion already arrived
                if completions.removeValue(forKey: ticket) != nil {
                    pthread_mutex_unlock(&mutex)
                    return
                }
                waiters[ticket] = waiter
                pthread_mutex_unlock(&mutex)
            }

            /// Simulates completion delivery (worker side)
            func complete(ticket: UInt64, value: Int) {
                pthread_mutex_lock(&mutex)
                // Check abandoned
                if abandoned.remove(ticket) != nil {
                    pthread_mutex_unlock(&mutex)
                    return
                }
                // Check waiter
                if waiters.removeValue(forKey: ticket) != nil {
                    pthread_mutex_unlock(&mutex)
                    return
                }
                // Store for later
                completions[ticket] = value
                pthread_mutex_unlock(&mutex)
            }
        }

        /// Simulates the proposed context-based approach.
        /// No dictionary lookup - worker has direct reference to context.
        final class ContextBasedState: @unchecked Sendable {
            private var mutex = pthread_mutex_t()

            init() {
                pthread_mutex_init(&mutex, nil)
            }

            deinit {
                pthread_mutex_destroy(&mutex)
            }

            /// Context that would be bundled with the job.
            /// Uses atomic state for exactly-once resumption.
            final class Context: @unchecked Sendable {
                private var state: UInt8 = 0  // 0=pending, 1=completed, 2=cancelled
                private var value: Int = 0

                func tryComplete(value: Int) -> Bool {
                    // Simulated atomic compareExchange
                    if state == 0 {
                        state = 1
                        self.value = value
                        return true
                    }
                    return false
                }
            }

            /// Simulates completion with bundled context (no lookup needed)
            func complete(context: Context, value: Int) {
                // No lock needed for completion - context owns its state
                _ = context.tryComplete(value: value)
            }
        }

        @Test(
            "dictionary-based: register + complete cycle",
            .timed(iterations: 5000, warmup: 500, trackAllocations: false)
        )
        func dictionaryBasedCycle() async throws {
            let state = DictionaryBasedState()
            let ticket: UInt64 = 42

            // Simulate the two-stage dance
            state.registerWaiter(ticket: ticket, waiter: 1)
            state.complete(ticket: ticket, value: 42)
        }

        @Test(
            "context-based: direct complete (no lookup)",
            .timed(iterations: 5000, warmup: 500, trackAllocations: false)
        )
        func contextBasedComplete() async throws {
            let state = ContextBasedState()
            let context = ContextBasedState.Context()

            // Single-stage - worker has context reference
            state.complete(context: context, value: 42)
        }

        @Test(
            "dictionary-based: concurrent register + complete",
            .timed(iterations: 1000, warmup: 100, trackAllocations: false)
        )
        func dictionaryBasedConcurrent() async throws {
            let state = DictionaryBasedState()
            let iterations = 100

            await withTaskGroup(of: Void.self) { group in
                // Simulate concurrent waiters registering
                for i in 0..<iterations {
                    group.addTask {
                        state.registerWaiter(ticket: UInt64(i), waiter: i)
                    }
                }
                // Simulate concurrent completions
                for i in 0..<iterations {
                    group.addTask {
                        state.complete(ticket: UInt64(i), value: i)
                    }
                }
            }
        }

        @Test(
            "context-based: concurrent complete",
            .timed(iterations: 1000, warmup: 100, trackAllocations: false)
        )
        func contextBasedConcurrent() async throws {
            let state = ContextBasedState()
            let iterations = 100

            // Pre-create contexts (would be created at job submission time)
            let contexts = (0..<iterations).map { _ in ContextBasedState.Context() }

            await withTaskGroup(of: Void.self) { group in
                // Simulate concurrent completions - no lock contention!
                for i in 0..<iterations {
                    group.addTask {
                        state.complete(context: contexts[i], value: i)
                    }
                }
            }
        }
    }
}

// MARK: - Baseline Comparisons

extension MicroBenchmarks.Test.Performance {

    /// Baseline measurements for comparison.
    @Suite("Baselines")
    struct Baselines {

        @Test(
            "baseline: empty async function call",
            .timed(iterations: 5000, warmup: 500, trackAllocations: false)
        )
        func emptyAsyncCall() async {
            // Measures pure async function call overhead
            await emptyAsync()
        }

        @Test(
            "baseline: Task spawn and await",
            .timed(iterations: 2000, warmup: 200, trackAllocations: false)
        )
        func taskSpawnAwait() async {
            let value = await Task { 42 }.value
            withExtendedLifetime(value) {}
        }

        private func emptyAsync() async {}
    }
}
