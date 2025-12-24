//
//  IO.Blocking.Threads Tests.swift
//  swift-io
//

import StandardsTestSupport
import Testing

@testable import IO_Blocking_Threads

extension IO.Blocking.Threads {
    #TestSuites
}

// MARK: - Unit Tests

extension IO.Blocking.Threads.Test.Unit {
    @Test("init with default options")
    func initDefaultOptions() {
        let threads = IO.Blocking.Threads()
        #expect(threads.capabilities.executesOnDedicatedThreads == true)
        #expect(threads.capabilities.guaranteesRunOnceEnqueued == true)
    }

    @Test("init with custom options")
    func initCustomOptions() {
        let options = IO.Blocking.Threads.Options(workers: 2, queueLimit: 64)
        let threads = IO.Blocking.Threads(options)
        #expect(threads.capabilities.executesOnDedicatedThreads == true)
    }

    @Test("capabilities are correct")
    func capabilitiesCorrect() {
        let threads = IO.Blocking.Threads()
        #expect(threads.capabilities.executesOnDedicatedThreads == true)
        #expect(threads.capabilities.guaranteesRunOnceEnqueued == true)
    }

    @Test("runBoxed executes operation")
    func runBoxedExecutes() async throws {
        let threads = IO.Blocking.Threads()
        defer { Task { await threads.shutdown() } }

        let ptr = try await threads.runBoxed(deadline: nil) {
            let value = 42
            let p = UnsafeMutablePointer<Int>.allocate(capacity: 1)
            p.initialize(to: value)
            return UnsafeMutableRawPointer(p)
        }
        let result = ptr.assumingMemoryBound(to: Int.self).pointee
        ptr.deallocate()
        #expect(result == 42)
    }

    @Test("shutdown completes gracefully")
    func shutdownCompletes() async {
        let threads = IO.Blocking.Threads()
        await threads.shutdown()
        // No hang = success
    }

    @Test("Sendable conformance")
    func sendableConformance() async {
        let threads = IO.Blocking.Threads()
        await Task {
            #expect(threads.capabilities.executesOnDedicatedThreads == true)
        }.value
        await threads.shutdown()
    }
}

// MARK: - Edge Cases

extension IO.Blocking.Threads.Test.EdgeCase {
    @Test("multiple sequential operations")
    func multipleSequentialOperations() async throws {
        let threads = IO.Blocking.Threads()
        defer { Task { await threads.shutdown() } }

        for i in 0..<10 {
            let ptr = try await threads.runBoxed(deadline: nil) {
                let p = UnsafeMutablePointer<Int>.allocate(capacity: 1)
                p.initialize(to: i)
                return UnsafeMutableRawPointer(p)
            }
            let result = ptr.assumingMemoryBound(to: Int.self).pointee
            ptr.deallocate()
            #expect(result == i)
        }
    }

    @Test("shutdown before any operations")
    func shutdownBeforeOperations() async {
        let threads = IO.Blocking.Threads()
        await threads.shutdown()
        // No hang = success
    }
}
