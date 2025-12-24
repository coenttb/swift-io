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

extension IO.Executor.Pool where Resource == TestResource {
    #TestSuites
}

// MARK: - Unit Tests

extension IO.Executor.Pool<TestResource>.Test.Unit {
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
        #expect(pool.lane.capabilities == lane.capabilities)
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
        defer { Task { await pool.shutdown() } }

        let result: Int = try await pool.run { 42 }
        #expect(result == 42)
    }

    @Test("register returns valid ID")
    func registerReturnsValidID() async throws {
        let pool = IO.Executor.Pool<TestResource>(lane: .inline)
        defer { Task { await pool.shutdown() } }

        let resource = TestResource(value: 100)
        let id = try await pool.register(resource)
        #expect(id.scope == pool.scope)
        #expect(await pool.isValid(id) == true)
    }

    @Test("isOpen returns true for open handle")
    func isOpenTrue() async throws {
        let pool = IO.Executor.Pool<TestResource>(lane: .inline)
        defer { Task { await pool.shutdown() } }

        let resource = TestResource(value: 100)
        let id = try await pool.register(resource)
        #expect(await pool.isOpen(id) == true)
    }

    @Test("transaction provides exclusive access")
    func transactionExclusiveAccess() async throws {
        let pool = IO.Executor.Pool<TestResource>(lane: .inline)
        defer { Task { await pool.shutdown() } }

        let resource = TestResource(value: 100)
        let id = try await pool.register(resource)

        let result: Int = try await pool.transaction(id) { resource in
            resource.value += 50
            return resource.value
        }
        #expect(result == 150)
    }

    @Test("destroy marks handle for destruction")
    func destroyMarksForDestruction() async throws {
        let pool = IO.Executor.Pool<TestResource>(lane: .inline)
        defer { Task { await pool.shutdown() } }

        let resource = TestResource(value: 100)
        let id = try await pool.register(resource)
        try await pool.destroy(id)
        #expect(await pool.isOpen(id) == false)
    }

    @Test("shutdown completes gracefully")
    func shutdownCompletes() async {
        let pool = IO.Executor.Pool<TestResource>(lane: .inline)
        await pool.shutdown()
        // No hang = success
    }
}

// MARK: - Edge Cases

extension IO.Executor.Pool<TestResource>.Test.EdgeCase {
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

    @Test("transaction with invalid ID throws")
    func transactionInvalidID() async {
        let pool = IO.Executor.Pool<TestResource>(lane: .inline)
        defer { Task { await pool.shutdown() } }

        let invalidID = IO.Handle.ID(raw: 999, scope: pool.scope)

        do {
            _ = try await pool.transaction(invalidID) { $0.value }
            Issue.record("Expected error for invalid ID")
        } catch {
            // Expected
        }
    }

    @Test("transaction with wrong scope throws")
    func transactionWrongScope() async {
        let pool = IO.Executor.Pool<TestResource>(lane: .inline)
        defer { Task { await pool.shutdown() } }

        let wrongScopeID = IO.Handle.ID(raw: 0, scope: pool.scope + 1)

        do {
            _ = try await pool.transaction(wrongScopeID) { $0.value }
            Issue.record("Expected error for wrong scope")
        } catch {
            // Expected
        }
    }

    @Test("isOpen with wrong scope returns false")
    func isOpenWrongScope() async {
        let pool = IO.Executor.Pool<TestResource>(lane: .inline)
        defer { Task { await pool.shutdown() } }

        let wrongScopeID = IO.Handle.ID(raw: 0, scope: pool.scope + 1)
        #expect(await pool.isOpen(wrongScopeID) == false)
    }

    @Test("destroy is idempotent")
    func destroyIdempotent() async throws {
        let pool = IO.Executor.Pool<TestResource>(lane: .inline)
        defer { Task { await pool.shutdown() } }

        let resource = TestResource(value: 100)
        let id = try await pool.register(resource)
        try await pool.destroy(id)
        // Second destroy should not throw
        try await pool.destroy(id)
    }

    @Test("shutdown is idempotent")
    func shutdownIdempotent() async {
        let pool = IO.Executor.Pool<TestResource>(lane: .inline)
        await pool.shutdown()
        await pool.shutdown()  // Should not hang
    }
}
