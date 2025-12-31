//
//  IO.Event.Selector.Shutdown.Tests.swift
//  swift-io
//

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

import StandardsTestSupport
import Testing

@testable import IO_Events
import IO_Events_Kqueue

extension IO.Event.Selector {
    #TestSuites
}

// MARK: - Shutdown Tests

extension IO.Event.Selector.Test {
    @Suite struct Shutdown {}
}

extension IO.Event.Selector.Test.Shutdown {
    @Test("shutdown rejects new registrations")
    func shutdownRejectsNewRegistrations() async throws {
        let executor = IO.Executor.Thread()
        let selector = try await IO.Event.Selector.make(
            driver: IO.Event.Kqueue.driver(),
            executor: executor
        )

        await selector.shutdown()

        // Attempt to register after shutdown should fail
        do {
            _ = try await selector.register(0, interest: IO.Event.Interest.read)
            Issue.record("register should throw after shutdown")
        } catch let error {
            // `error` is typed as IO.Event.Failure, no `as` cast needed
            switch error {
            case .shutdownInProgress:
                break // Expected
            default:
                Issue.record("Expected shutdownInProgress, got \(error)")
            }
        }
    }

    @Test("shutdown drains pending replies with shutdownInProgress (race)")
    func shutdownDrainsPendingRepliesRace() async throws {
        // This test races registration against shutdown to verify that
        // pending reply continuations are drained with the correct lifecycle
        // error (.shutdownInProgress), not a leaf error.
        //
        // We run multiple iterations to increase the chance of hitting the race.
        // The invariant: if registration fails, it MUST fail with .shutdownInProgress.

        for iteration in 0..<10 {
            let executor = IO.Executor.Thread()
            let selector = try await IO.Event.Selector.make(
                driver: IO.Event.Kqueue.driver(),
                executor: executor
            )

            // Create a valid pipe FD
            var fds: (Int32, Int32) = (0, 0)
            let pipeResult = withUnsafeMutablePointer(to: &fds) { ptr in
                ptr.withMemoryRebound(to: Int32.self, capacity: 2) { pipe($0) }
            }
            guard pipeResult == 0 else {
                Issue.record("Failed to create pipe")
                continue
            }
            defer {
                close(fds.0)
                close(fds.1)
            }

            // Start registration in a Task (may be pending when shutdown hits)
            let readFD = fds.0
            let registerTask = Task {
                do throws(IO.Event.Failure) {
                    _ = try await selector.register(readFD, interest: IO.Event.Interest.read)
                    return Result<Void, IO.Event.Failure>.success(())
                } catch {
                    // `error` is typed as IO.Event.Failure
                    return Result<Void, IO.Event.Failure>.failure(error)
                }
            }

            // Race: shutdown while registration may be pending
            await selector.shutdown()

            // Wait for registration to complete
            let result = await registerTask.value

            // Verify invariant: if failed, must be .shutdownInProgress
            switch result {
            case .success:
                // Registration completed before shutdown - that's fine
                break
            case .failure(let error):
                switch error {
                case .shutdownInProgress:
                    // Correct - pending reply was drained with lifecycle error
                    break
                case .failure(let leaf):
                    Issue.record("Iteration \(iteration): pending reply drained with leaf error .failure(\(leaf)), expected .shutdownInProgress")
                case .cancelled:
                    Issue.record("Iteration \(iteration): got .cancelled, expected .shutdownInProgress")
                case .timeout:
                    Issue.record("Iteration \(iteration): got .timeout, expected .shutdownInProgress")
                }
            }
        }
    }

    @Test("shutdown gate: operations after shutdown throw")
    func shutdownGate() async throws {
        let executor = IO.Executor.Thread()
        let selector = try await IO.Event.Selector.make(
            driver: IO.Event.Kqueue.driver(),
            executor: executor
        )

        await selector.shutdown()

        // All operations should throw shutdownInProgress

        // register
        do {
            _ = try await selector.register(0, interest: IO.Event.Interest.read)
            Issue.record("register should throw")
        } catch let error {
            switch error {
            case .shutdownInProgress:
                break // Expected
            default:
                Issue.record("Expected shutdownInProgress, got \(error)")
            }
        }
    }

    @Test("double shutdown is idempotent")
    func doubleShutdownIdempotent() async throws {
        let executor = IO.Executor.Thread()
        let selector = try await IO.Event.Selector.make(
            driver: IO.Event.Kqueue.driver(),
            executor: executor
        )

        // First shutdown
        await selector.shutdown()

        // Second shutdown should be a no-op
        await selector.shutdown()

        // Should still reject operations
        do {
            _ = try await selector.register(0, interest: IO.Event.Interest.read)
            Issue.record("register should throw")
        } catch {
            // Expected
        }
    }
}

// MARK: - Invariant Tests

extension IO.Event.Selector.Test {
    @Suite struct Invariants {}
}

extension IO.Event.Selector.Test.Invariants {
    @Test("typed errors: lifecycle is not a leaf error")
    func typedErrorsLifecycleNotLeaf() async throws {
        let executor = IO.Executor.Thread()
        let selector = try await IO.Event.Selector.make(
            driver: IO.Event.Kqueue.driver(),
            executor: executor
        )

        await selector.shutdown()

        do {
            _ = try await selector.register(0, interest: IO.Event.Interest.read)
            Issue.record("Should throw")
        } catch let error {
            // Verify this is a lifecycle error, not wrapped in .failure()
            // `error` is typed as IO.Event.Failure, no `as` cast needed
            switch error {
            case .shutdownInProgress:
                // Correct - this is a lifecycle error at the top level
                break
            case .cancelled:
                Issue.record("Expected shutdownInProgress, got cancelled")
            case .timeout:
                Issue.record("Expected shutdownInProgress, got timeout")
            case .failure(let leaf):
                Issue.record("Lifecycle error should not be wrapped as .failure(\(leaf))")
            }
        }
    }
}
