//
//  IO.Thread Tests.swift
//  swift-io
//

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

    @Test("Handle.isCurrentThread returns false from main thread")
    func isCurrentThreadFalseFromMain() throws {
        let handle = try IO.Thread.spawn {
            // Do nothing
        }

        // From main thread, isCurrentThread should be false
        #expect(handle.isCurrentThread == false)

        handle.join()
    }
}

// MARK: - Spawn.Error Tests

extension IO.Thread.Spawn.Error {
    #TestSuites
}

extension IO.Thread.Spawn.Error.Test.Unit {
    @Test("Error stores platform and code correctly")
    func errorStoresPlatformAndCode() {
        let error = IO.Thread.Spawn.Error(platform: .pthread, code: 42)
        #expect(error.platform == .pthread)
        #expect(error.code == 42)
    }

    @Test("Error is Equatable")
    func errorIsEquatable() {
        let e1 = IO.Thread.Spawn.Error(platform: .pthread, code: 11)
        let e2 = IO.Thread.Spawn.Error(platform: .pthread, code: 11)
        let e3 = IO.Thread.Spawn.Error(platform: .pthread, code: 22)
        let e4 = IO.Thread.Spawn.Error(platform: .windows, code: 11)

        #expect(e1 == e2)
        #expect(e1 != e3)
        #expect(e1 != e4)  // Different platform
    }

    @Test("Error description includes code")
    func errorDescriptionIncludesCode() {
        let error = IO.Thread.Spawn.Error(platform: .pthread, code: 99)
        #expect(error.description.contains("99"))
        #expect(error.description.contains("pthread"))
    }

    @Test("Error description varies by platform")
    func errorDescriptionVariesByPlatform() {
        let pthreadError = IO.Thread.Spawn.Error(platform: .pthread, code: 11)
        let windowsError = IO.Thread.Spawn.Error(platform: .windows, code: 11)

        #expect(pthreadError.description.contains("pthread"))
        #expect(windowsError.description.contains("CreateThread"))
    }
}
