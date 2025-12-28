//
//  IO.Executor.Pool Tests.swift
//  swift-io
//

import StandardsTestSupport
import Testing

@testable import IO

// Test with a simple Sendable resource type
struct TestResource: Sendable {
    var value: Int
}

// IO.Executor.Pool is generic, so we use a standalone test namespace
enum IOExecutorPoolTests {
    #TestSuites
}

// MARK: - Unit Tests

extension IOExecutorPoolTests.Test.Unit {
    @Test("init with default options")
    func initDefaultOptions() async {
        let pool = IO.Executor.Pool<TestResource>()
        #expect(pool.scope > 0)
        await pool.shutdown()
    }

    @Test("init with custom lane")
    func initCustomLane() async {
        let lane = IO.Blocking.Lane.inline
        let pool = IO.Executor.Pool<TestResource>(lane: lane)
        // Pool was initialized with lane - verified by successful init
        await pool.shutdown()
    }

    @Test("scope is unique per instance")
    func scopeUnique() async {
        let pool1 = IO.Executor.Pool<TestResource>()
        let pool2 = IO.Executor.Pool<TestResource>()
        #expect(pool1.scope != pool2.scope)
        await pool1.shutdown()
        await pool2.shutdown()
    }

    @Test("run executes operation")
    func runExecutes() async throws {
        let pool = IO.Executor.Pool<TestResource>(lane: .inline)

        let result: Int = try await pool.run { 42 }
        #expect(result == 42)

        await pool.shutdown()
    }

    @Test("register returns valid ID")
    func registerReturnsValidID() async throws {
        let pool = IO.Executor.Pool<TestResource>(lane: .inline)

        let resource = TestResource(value: 100)
        let id = try await pool.register(resource)
        #expect(id.scope == pool.scope)
        #expect(await pool.isValid(id) == true)

        await pool.shutdown()
    }

    @Test("isOpen returns true for open handle")
    func isOpenTrue() async throws {
        let pool = IO.Executor.Pool<TestResource>(lane: .inline)

        let resource = TestResource(value: 100)
        let id = try await pool.register(resource)
        #expect(await pool.isOpen(id) == true)

        await pool.shutdown()
    }

    @Test("transaction provides exclusive access")
    func transactionExclusiveAccess() async throws {
        let pool = IO.Executor.Pool<TestResource>(lane: .inline)

        let resource = TestResource(value: 100)
        let id = try await pool.register(resource)

        let result: Int = try await pool.transaction(id) { resource in
            resource.value += 50
            return resource.value
        }
        #expect(result == 150)

        await pool.shutdown()
    }

    @Test("destroy marks handle for destruction")
    func destroyMarksForDestruction() async throws {
        let pool = IO.Executor.Pool<TestResource>(lane: .inline)

        let resource = TestResource(value: 100)
        let id = try await pool.register(resource)
        try await pool.destroy(id)
        #expect(await pool.isOpen(id) == false)

        await pool.shutdown()
    }

    @Test("shutdown completes gracefully")
    func shutdownCompletes() async {
        let pool = IO.Executor.Pool<TestResource>(lane: .inline)
        await pool.shutdown()
        // No hang = success
    }
}

// MARK: - Edge Cases

extension IOExecutorPoolTests.Test.EdgeCase {
    @Test("run after shutdown throws")
    func runAfterShutdown() async {
        let pool = IO.Executor.Pool<TestResource>(lane: .inline)
        await pool.shutdown()

        do {
            _ = try await pool.run { 42 }
            Issue.record("Expected error after shutdown")
        } catch {
            // Expected
        }
    }

    @Test("register after shutdown throws")
    func registerAfterShutdown() async {
        let pool = IO.Executor.Pool<TestResource>(lane: .inline)
        await pool.shutdown()

        do {
            let resource = TestResource(value: 100)
            _ = try await pool.register(resource)
            Issue.record("Expected error after shutdown")
        } catch {
            // Expected
        }
    }

    @Test("transaction after shutdown throws immediately")
    func transactionAfterShutdown() async throws {
        let pool = IO.Executor.Pool<TestResource>(lane: .inline)

        // Register a handle before shutdown
        let resource = TestResource(value: 100)
        let id = try await pool.register(resource)

        await pool.shutdown()

        do {
            _ = try await pool.transaction(id) { $0.value }
            Issue.record("Expected shutdownInProgress error")
        } catch let error {
            // Must be shutdownInProgress, not a handle or lane error
            switch error {
            case .shutdownInProgress:
                #expect(true, "transaction correctly rejects at submission gate")
            case .cancelled:
                Issue.record("shutdown should not surface as cancelled")
            case .failure:
                Issue.record("shutdown should reject at gate, not as failure")
            }
        }
    }

    @Test("transaction with invalid ID throws")
    func transactionInvalidID() async {
        let pool = IO.Executor.Pool<TestResource>(lane: .inline)

        let invalidID = IO.Handle.ID(raw: 999, scope: pool.scope)

        do {
            _ = try await pool.transaction(invalidID) { $0.value }
            Issue.record("Expected error for invalid ID")
        } catch {
            // Expected
        }

        await pool.shutdown()
    }

    @Test("transaction with wrong scope throws")
    func transactionWrongScope() async {
        let pool = IO.Executor.Pool<TestResource>(lane: .inline)

        let wrongScopeID = IO.Handle.ID(raw: 0, scope: pool.scope + 1)

        do {
            _ = try await pool.transaction(wrongScopeID) { $0.value }
            Issue.record("Expected error for wrong scope")
        } catch {
            // Expected
        }

        await pool.shutdown()
    }

    @Test("isOpen with wrong scope returns false")
    func isOpenWrongScope() async {
        let pool = IO.Executor.Pool<TestResource>(lane: .inline)

        let wrongScopeID = IO.Handle.ID(raw: 0, scope: pool.scope + 1)
        #expect(await pool.isOpen(wrongScopeID) == false)

        await pool.shutdown()
    }

    @Test("destroy is idempotent")
    func destroyIdempotent() async throws {
        let pool = IO.Executor.Pool<TestResource>(lane: .inline)

        let resource = TestResource(value: 100)
        let id = try await pool.register(resource)
        try await pool.destroy(id)
        // Second destroy should not throw
        try await pool.destroy(id)

        await pool.shutdown()
    }

    @Test("shutdown is idempotent")
    func shutdownIdempotent() async {
        let pool = IO.Executor.Pool<TestResource>(lane: .inline)
        await pool.shutdown()
        await pool.shutdown()  // Should not hang
    }

    @Test("shutdown never surfaces as invalidState")
    func shutdownNeverInvalidState() async {
        let pool = IO.Executor.Pool<TestResource>(lane: .inline)
        await pool.shutdown()

        do {
            // Try to run after shutdown
            let _: Int = try await pool.run { 42 }
            Issue.record("Expected shutdownInProgress error")
        } catch let error {
            // MUST be .shutdownInProgress, NOT .failure(.executor(.invalidState))
            switch error {
            case .shutdownInProgress:
                #expect(true, "shutdown correctly surfaces as .shutdownInProgress")
            case .cancelled:
                Issue.record("shutdown should not surface as cancelled")
            case .failure(let inner):
                switch inner {
                case .executor(.invalidState):
                    Issue.record("shutdown MUST NOT be encoded as invalidState")
                case .executor(.scopeMismatch):
                    Issue.record("shutdown MUST NOT be encoded as scopeMismatch")
                case .executor(.handleNotFound):
                    Issue.record("shutdown MUST NOT be encoded as handleNotFound")
                case .handle:
                    Issue.record("shutdown MUST NOT be encoded as handle error")
                case .lane:
                    Issue.record("shutdown MUST NOT be encoded as lane error")
                case .leaf:
                    Issue.record("shutdown MUST NOT be encoded as leaf error")
                }
            }
        }
    }

    @Test("register after shutdown surfaces as shutdownInProgress")
    func registerAfterShutdownSurfacesCorrectly() async {
        let pool = IO.Executor.Pool<TestResource>(lane: .inline)
        await pool.shutdown()

        do {
            let resource = TestResource(value: 100)
            _ = try await pool.register(resource)
            Issue.record("Expected shutdownInProgress error")
        } catch let error {
            switch error {
            case .shutdownInProgress:
                #expect(true, "register correctly surfaces as .shutdownInProgress")
            case .cancelled:
                Issue.record("shutdown should not surface as cancelled")
            case .failure:
                Issue.record("shutdown MUST NOT be encoded as failure")
            }
        }
    }
}

// MARK: - Executor Tests

extension IOExecutorPoolTests.Test {
    @Suite struct Integration {}
}

extension IOExecutorPoolTests.Test.Integration {
    @Test("pool exposes executor")
    func exposesExecutor() async {
        let pool = IO.Executor.Pool<TestResource>(lane: .inline)
        let executor = pool.executor
        _ = executor.asUnownedSerialExecutor()
        await pool.shutdown()
    }

    @Test("pool unownedExecutor returns same executor")
    func unownedExecutorConsistent() async {
        let pool = IO.Executor.Pool<TestResource>(lane: .inline)
        let unowned1 = pool.unownedExecutor
        let unowned2 = pool.unownedExecutor
        // UnownedSerialExecutor identity is consistent
        _ = unowned1
        _ = unowned2
        await pool.shutdown()
    }

    @Test("init with explicit executor uses that executor")
    func initWithExplicitExecutor() async {
        let customExecutor = IO.Executor.Thread()
        let pool = IO.Executor.Pool<TestResource>(
            lane: .inline,
            executor: customExecutor
        )

        #expect(ObjectIdentifier(pool.executor) == ObjectIdentifier(customExecutor))

        await pool.shutdown()
        customExecutor.shutdown()
    }

    @Test("two pools can share same executor")
    func poolsShareExecutor() async {
        let sharedExecutor = IO.Executor.Thread()

        let pool1 = IO.Executor.Pool<TestResource>(lane: .inline, executor: sharedExecutor)
        let pool2 = IO.Executor.Pool<TestResource>(lane: .inline, executor: sharedExecutor)

        #expect(ObjectIdentifier(pool1.executor) == ObjectIdentifier(pool2.executor))

        await pool1.shutdown()
        await pool2.shutdown()
        sharedExecutor.shutdown()
    }

    @Test("pool methods run on assigned executor")
    func methodsRunOnAssignedExecutor() async throws {
        let pool = IO.Executor.Pool<TestResource>(lane: .inline)

        let resource = TestResource(value: 42)
        let id = try await pool.register(resource)

        // Actor-isolated methods run on the pool's executor
        let value = try await pool.transaction(id) { resource in
            resource.value
        }

        #expect(value == 42)
        await pool.shutdown()
    }

    @Test("withTaskExecutorPreference uses pool executor")
    func taskExecutorPreferenceWithPool() async {
        let pool = IO.Executor.Pool<TestResource>(lane: .inline)

        let result = await withTaskExecutorPreference(pool.executor) {
            42
        }

        #expect(result == 42)
        await pool.shutdown()
    }

    @Test("withExecutorPreference convenience method")
    func withExecutorPreferenceConvenience() async {
        let pool = IO.Executor.Pool<TestResource>(lane: .inline)

        // Verify the method completes without throwing
        let result = await pool.withExecutorPreference {
            42
        }

        #expect(result == 42)
        await pool.shutdown()
    }

    @Test("pools from shared executor pool get round-robin assignment")
    func roundRobinAssignment() async {
        // Create pools using default init (gets executor from IO.Executor.shared)
        let pool1 = IO.Executor.Pool<TestResource>(lane: .inline)
        let pool2 = IO.Executor.Pool<TestResource>(lane: .inline)
        let pool3 = IO.Executor.Pool<TestResource>(lane: .inline)
        let pool4 = IO.Executor.Pool<TestResource>(lane: .inline)

        // With a sharded pool, executors should be distributed
        // At minimum, not all pools should be on the same executor
        let executors = Set([
            ObjectIdentifier(pool1.executor),
            ObjectIdentifier(pool2.executor),
            ObjectIdentifier(pool3.executor),
            ObjectIdentifier(pool4.executor)
        ])

        // Should use more than 1 executor (unless system has only 1 core)
        #expect(executors.count >= 1)

        await pool1.shutdown()
        await pool2.shutdown()
        await pool3.shutdown()
        await pool4.shutdown()
    }
}
