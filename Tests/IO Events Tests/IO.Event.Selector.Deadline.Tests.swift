//
//  IO.Event.Selector.Deadline.Tests.swift
//  swift-io
//

import IO_Events_Kqueue
import Kernel
import Testing

@testable import IO_Events

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

@Suite("IO.Event.Selector.Deadline")
struct SelectorDeadlineTests {}

// MARK: - Helpers

extension SelectorDeadlineTests {
    /// Helper to create a non-blocking pipe
    private static func makeNonBlockingPipe() throws -> (read: Int32, write: Int32) {
        var fds: (Int32, Int32) = (0, 0)
        let result = withUnsafeMutablePointer(to: &fds) { ptr in
            ptr.withMemoryRebound(to: Int32.self, capacity: 2) { pipe($0) }
        }
        guard result == 0 else {
            throw IO.Event.Error.platform(.posix(errno))
        }

        // Set non-blocking mode
        var flags = fcntl(fds.0, F_GETFL)
        _ = fcntl(fds.0, F_SETFL, flags | O_NONBLOCK)
        flags = fcntl(fds.1, F_GETFL)
        _ = fcntl(fds.1, F_SETFL, flags | O_NONBLOCK)

        return fds
    }
}

// MARK: - Timeout Fires Tests

extension SelectorDeadlineTests {
    @Test("arm with deadline times out when no event arrives")
    func armWithDeadlineTimesOut() async throws {
        let executor = Kernel.Thread.Executor()
        let selector = try await IO.Event.Selector.make(
            driver: IO.Event.Kqueue.driver(),
            executor: executor
        )

        let pipe = try Self.makeNonBlockingPipe()
        defer {
            close(pipe.read)
            close(pipe.write)
        }

        // Register the read end
        let registration = try await selector.register(pipe.read, interest: .read)

        // Arm with a short deadline (50ms) - no data will be written
        // This tests: deadline scheduling, tick wake path, timeout delivery
        let deadline = IO.Event.Deadline.after(milliseconds: 50)

        do {
            _ = try await selector.arm(registration.token, interest: .read, deadline: deadline)
            Issue.record("Expected timeout but arm succeeded")
        } catch {
            switch error {
            case .timeout:
                break  // Expected - timeout was delivered
            default:
                Issue.record("Expected .timeout, got \(error)")
            }
        }

        await selector.shutdown()
    }

    @Test("event beats timeout when data arrives before deadline")
    func eventBeatsTimeout() async throws {
        let executor = Kernel.Thread.Executor()
        let selector = try await IO.Event.Selector.make(
            driver: IO.Event.Kqueue.driver(),
            executor: executor
        )

        let pipe = try Self.makeNonBlockingPipe()
        defer {
            close(pipe.read)
            close(pipe.write)
        }

        // Write data before arming - event is already pending
        let testData: [UInt8] = [1, 2, 3]
        _ = Darwin.write(pipe.write, testData, testData.count)

        // Register the read end
        let registration = try await selector.register(pipe.read, interest: .read)

        // Arm with a generous deadline - event should arrive first via permit path
        let deadline = IO.Event.Deadline.after(milliseconds: 5000)

        // Event should win over timeout since data is already available
        let result = try await selector.arm(registration.token, interest: .read, deadline: deadline)

        #expect(result.event.interest.contains(.read), "Expected read interest in event")

        // Clean up
        _ = consume result.token
        await selector.shutdown()
    }

    @Test("tick wakes selector when only deadlines are pending")
    func tickWakesSelectorForDeadlineOnly() async throws {
        // This test verifies the tick() path: poll times out with no events,
        // but deadline has expired, so selector drains and resumes waiter.
        let executor = Kernel.Thread.Executor()
        let selector = try await IO.Event.Selector.make(
            driver: IO.Event.Kqueue.driver(),
            executor: executor
        )

        let pipe = try Self.makeNonBlockingPipe()
        defer {
            close(pipe.read)
            close(pipe.write)
        }

        // Register but never write data - only deadline can wake us
        let registration = try await selector.register(pipe.read, interest: .read)

        let start = IO.Event.Deadline.now
        let deadline = IO.Event.Deadline.after(milliseconds: 30)

        do {
            _ = try await selector.arm(registration.token, interest: .read, deadline: deadline)
            Issue.record("Expected timeout")
        } catch {
            switch error {
            case .timeout:
                // Verify we actually waited (not instant)
                let elapsed = IO.Event.Deadline.now.nanoseconds - start.nanoseconds
                #expect(elapsed >= 25_000_000, "Should have waited ~30ms, got \(elapsed / 1_000_000)ms")
            default:
                Issue.record("Expected .timeout, got \(error)")
            }
        }

        await selector.shutdown()
    }
}

// MARK: - Stale Entry Tests

extension SelectorDeadlineTests {
    @Test("stale heap entry does not fire after waiter completes")
    func staleHeapEntryDoesNotFire() async throws {
        // Test: arm with short deadline, let it timeout (heap entry created),
        // then register again and arm without deadline. The stale heap entry
        // should be skipped via generation mismatch.
        let executor = Kernel.Thread.Executor()
        let selector = try await IO.Event.Selector.make(
            driver: IO.Event.Kqueue.driver(),
            executor: executor
        )

        let pipe = try Self.makeNonBlockingPipe()
        defer {
            close(pipe.read)
            close(pipe.write)
        }

        // First: register and arm with short deadline, let it timeout
        let reg1 = try await selector.register(pipe.read, interest: .read)
        let deadline = IO.Event.Deadline.after(milliseconds: 30)

        do {
            _ = try await selector.arm(reg1.token, interest: .read, deadline: deadline)
            Issue.record("Expected timeout")
        } catch {
            switch error {
            case .timeout:
                break  // Expected
            default:
                Issue.record("Expected .timeout, got \(error)")
            }
        }

        // Now: write data and register again
        let testData: [UInt8] = [1, 2, 3]
        _ = Darwin.write(pipe.write, testData, testData.count)

        let reg2 = try await selector.register(pipe.read, interest: .read)

        // Arm without deadline - should succeed immediately because data is available
        // The stale heap entry from reg1 should be skipped (generation mismatch)
        let result = try await selector.arm(reg2.token, interest: .read)

        #expect(result.event.interest.contains(.read), "Expected read interest in event")

        _ = consume result.token
        await selector.shutdown()
    }

    @Test("event delivery bumps generation, invalidating pending deadline")
    func eventBumpsGeneration() async throws {
        // Test: arm with long deadline, event arrives, generation bumps.
        let executor = Kernel.Thread.Executor()
        let selector = try await IO.Event.Selector.make(
            driver: IO.Event.Kqueue.driver(),
            executor: executor
        )

        let pipe = try Self.makeNonBlockingPipe()
        defer {
            close(pipe.read)
            close(pipe.write)
        }

        // Write data first
        let testData: [UInt8] = [1, 2, 3]
        _ = Darwin.write(pipe.write, testData, testData.count)

        let reg = try await selector.register(pipe.read, interest: .read)

        // Arm with very long deadline
        let deadline = IO.Event.Deadline.after(milliseconds: 60_000)

        // Should return immediately with event (not wait for deadline)
        let start = IO.Event.Deadline.now
        let result = try await selector.arm(reg.token, interest: .read, deadline: deadline)
        let elapsed = IO.Event.Deadline.now.nanoseconds - start.nanoseconds

        #expect(result.event.interest.contains(.read))
        #expect(elapsed < 1_000_000_000, "Should complete quickly, not wait for deadline")

        _ = consume result.token
        await selector.shutdown()
    }
}

// MARK: - Concurrent Deadlines Tests

extension SelectorDeadlineTests {
    @Test("concurrent deadlines both fire correctly")
    func concurrentDeadlinesBothFire() async throws {
        // Test multiple pending deadlines simultaneously using armTwo.
        // Validates: heap ordering, updateNextPollDeadline, stale entry handling.
        let executor = Kernel.Thread.Executor()
        let selector = try await IO.Event.Selector.make(
            driver: IO.Event.Kqueue.driver(),
            executor: executor
        )

        let pipe1 = try Self.makeNonBlockingPipe()
        let pipe2 = try Self.makeNonBlockingPipe()
        defer {
            close(pipe1.read)
            close(pipe1.write)
            close(pipe2.read)
            close(pipe2.write)
        }

        let reg1 = try await selector.register(pipe1.read, interest: .read)
        let reg2 = try await selector.register(pipe2.read, interest: .read)

        // Different deadlines - first should complete around 30ms, second around 60ms
        let d1 = IO.Event.Deadline.after(milliseconds: 30)
        let d2 = IO.Event.Deadline.after(milliseconds: 60)

        let start = IO.Event.Deadline.now

        // Use armTwo - creates both waiters before either completes
        let (outcome1, outcome2) = await selector.armTwo(
            IO.Event.Arm.Request(token: reg1.token, interest: .read, deadline: d1),
            IO.Event.Arm.Request(token: reg2.token, interest: .read, deadline: d2)
        )

        let elapsed = IO.Event.Deadline.now.nanoseconds - start.nanoseconds

        // Both should timeout
        switch outcome1 {
        case .armed:
            Issue.record("Outcome 1 should have timed out, but got armed")
        case .failed(let failure):
            switch failure {
            case .timeout:
                break  // Expected
            default:
                Issue.record("Outcome 1 expected .timeout, got \(failure)")
            }
        }

        switch outcome2 {
        case .armed:
            Issue.record("Outcome 2 should have timed out, but got armed")
        case .failed(let failure):
            switch failure {
            case .timeout:
                break  // Expected
            default:
                Issue.record("Outcome 2 expected .timeout, got \(failure)")
            }
        }

        // Total elapsed should be roughly d2 (longer deadline drives completion)
        // Allow slack: at least 50ms, less than 150ms
        let elapsedMs = elapsed / 1_000_000
        #expect(elapsedMs >= 50, "Total elapsed should be at least ~50ms, got \(elapsedMs)ms")
        #expect(elapsedMs < 150, "Total elapsed should be under ~150ms, got \(elapsedMs)ms")

        await selector.shutdown()
    }

    @Test("sequential deadlines smoke test")
    func sequentialDeadlinesSmoke() async throws {
        // Simple smoke test: two deadlines in sequence both fire.
        let executor = Kernel.Thread.Executor()
        let selector = try await IO.Event.Selector.make(
            driver: IO.Event.Kqueue.driver(),
            executor: executor
        )

        let pipe1 = try Self.makeNonBlockingPipe()
        let pipe2 = try Self.makeNonBlockingPipe()
        defer {
            close(pipe1.read)
            close(pipe1.write)
            close(pipe2.read)
            close(pipe2.write)
        }

        // First deadline
        let reg1 = try await selector.register(pipe1.read, interest: .read)
        let deadline1 = IO.Event.Deadline.after(milliseconds: 30)

        do {
            _ = try await selector.arm(reg1.token, interest: .read, deadline: deadline1)
            Issue.record("Expected timeout for first arm")
        } catch {
            switch error {
            case .timeout:
                break  // Expected
            default:
                Issue.record("Expected .timeout for first, got \(error)")
            }
        }

        // Second deadline
        let reg2 = try await selector.register(pipe2.read, interest: .read)
        let deadline2 = IO.Event.Deadline.after(milliseconds: 30)

        do {
            _ = try await selector.arm(reg2.token, interest: .read, deadline: deadline2)
            Issue.record("Expected timeout for second arm")
        } catch {
            switch error {
            case .timeout:
                break  // Expected
            default:
                Issue.record("Expected .timeout for second, got \(error)")
            }
        }

        await selector.shutdown()
    }
}

// MARK: - Deadline Helpers Tests

extension SelectorDeadlineTests {
    @Test("Deadline.after creates future deadline")
    func deadlineAfterCreatesFuture() {
        let now = IO.Event.Deadline.now
        let deadline = IO.Event.Deadline.after(milliseconds: 100)

        #expect(deadline.nanoseconds > now.nanoseconds)
        #expect(!deadline.hasExpired)
    }

    @Test("expired deadline reports hasExpired true")
    func expiredDeadlineHasExpiredTrue() async throws {
        let deadline = IO.Event.Deadline.after(milliseconds: 10)

        // Wait for deadline to expire
        try await Task.sleep(nanoseconds: 20_000_000)  // 20ms

        #expect(deadline.hasExpired)
    }

    @Test("Deadline.never never expires")
    func deadlineNeverNeverExpires() {
        let deadline = IO.Event.Deadline.never
        #expect(!deadline.hasExpired)
        #expect(deadline.nanoseconds == .max)
    }
}

// MARK: - MinHeap Unit Tests

extension SelectorDeadlineTests {
    @Test("MinHeap orders by deadline")
    func minHeapOrdersByDeadline() {
        typealias Entry = IO.Event.DeadlineScheduling.Entry
        typealias MinHeap = IO.Event.DeadlineScheduling.MinHeap

        var heap = MinHeap()

        // Insert in non-sorted order
        heap.push(Entry(deadline: 300, key: IO.Event.Selector.PermitKey(id: IO.Event.ID(1 as UInt), interest: .read), generation: 1))
        heap.push(Entry(deadline: 100, key: IO.Event.Selector.PermitKey(id: IO.Event.ID(2 as UInt), interest: .read), generation: 1))
        heap.push(Entry(deadline: 200, key: IO.Event.Selector.PermitKey(id: IO.Event.ID(3 as UInt), interest: .read), generation: 1))

        // Should pop in deadline order
        #expect(heap.pop()?.deadline == 100)
        #expect(heap.pop()?.deadline == 200)
        #expect(heap.pop()?.deadline == 300)
        #expect(heap.pop() == nil)
    }

    @Test("MinHeap peek doesn't remove")
    func minHeapPeekDoesntRemove() {
        typealias Entry = IO.Event.DeadlineScheduling.Entry
        typealias MinHeap = IO.Event.DeadlineScheduling.MinHeap

        var heap = MinHeap()
        heap.push(Entry(deadline: 100, key: IO.Event.Selector.PermitKey(id: IO.Event.ID(1 as UInt), interest: .read), generation: 1))

        #expect(heap.peek()?.deadline == 100)
        #expect(heap.peek()?.deadline == 100)  // Still there
        #expect(heap.count == 1)
    }
}
