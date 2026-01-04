//
//  IO.Thread Tests.swift
//  swift-io
//

import Kernel
import StandardsTestSupport
import Synchronization
import Testing

@testable import IO_Primitives

extension IO.Thread {
    #TestSuites
}

// MARK: - Unit Tests

extension IO.Thread.Test.Unit {
    @Test("spawn creates thread that executes body")
    func spawnExecutesBody() throws {
        let executed = Atomic<Bool>(false)
        let handle = try IO.Thread.spawn {
            executed.store(true, ordering: .releasing)
        }
        handle.join()
        #expect(executed.load(ordering: .acquiring) == true)
    }

    @Test("spawn with value transfers ownership")
    func spawnWithValueTransfersOwnership() throws {
        let receivedValue = Atomic<Int>(0)
        let handle = try IO.Thread.spawn(42) { value in
            receivedValue.store(value, ordering: .releasing)
        }
        handle.join()
        #expect(receivedValue.load(ordering: .acquiring) == 42)
    }

    @Test("Handle.join waits for thread completion")
    func handleJoinWaits() throws {
        let completed = Atomic<Bool>(false)
        let handle = try IO.Thread.spawn {
            // Small delay to ensure we're actually waiting
            for _ in 0..<1000 {
                _ = 1 + 1  // Busy work
            }
            completed.store(true, ordering: .releasing)
        }

        handle.join()
        #expect(completed.load(ordering: .acquiring) == true)
    }

    @Test("Handle.isCurrent returns false from main thread")
    func isCurrentFalseFromMain() throws {
        let handle = try IO.Thread.spawn {
            // Do nothing
        }

        // From main thread, isCurrent should be false
        #expect(handle.isCurrent == false)

        handle.join()
    }
}

// MARK: - Spawn.Error Tests

extension IO.Thread.Spawn.Error {
    #TestSuites
}

extension IO.Thread.Spawn.Error.Test.Unit {
    @Test("Error wraps kernel error correctly")
    func errorWrapsKernelError() {
        let kernelError = Kernel.Thread.Error.create(.posix(42))
        let error = IO.Thread.Spawn.Error(kernelError)

        if case .create(let code) = error.kernelError {
            #expect(code == .posix(42))
        } else {
            Issue.record("Expected .create case")
        }
    }

    @Test("Error is Equatable")
    func errorIsEquatable() {
        let e1 = IO.Thread.Spawn.Error(Kernel.Thread.Error.create(.posix(11)))
        let e2 = IO.Thread.Spawn.Error(Kernel.Thread.Error.create(.posix(11)))
        let e3 = IO.Thread.Spawn.Error(Kernel.Thread.Error.create(.posix(22)))
        let e4 = IO.Thread.Spawn.Error(Kernel.Thread.Error.join(.posix(11)))

        #expect(e1 == e2)
        #expect(e1 != e3)
        #expect(e1 != e4)  // Different error type
    }

    @Test("Error description includes context")
    func errorDescriptionIncludesContext() {
        let error = IO.Thread.Spawn.Error(Kernel.Thread.Error.create(.posix(99)))
        #expect(error.description.contains("creation") || error.description.contains("99"))
    }

    @Test("Error description varies by operation")
    func errorDescriptionVariesByOperation() {
        let createError = IO.Thread.Spawn.Error(Kernel.Thread.Error.create(.posix(11)))
        let joinError = IO.Thread.Spawn.Error(Kernel.Thread.Error.join(.posix(11)))

        #expect(createError.description.contains("creation"))
        #expect(joinError.description.contains("join"))
    }
}
