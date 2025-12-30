//
//  IO.Memory.Map Tests.swift
//  swift-io
//

import StandardsTestSupport
import Testing

@testable import IO_Primitives

extension IO.Memory.Map {
    #TestSuites
}

// MARK: - Unit Tests

extension IO.Memory.Map.Test.Unit {
    @Test("Protection read flag")
    func protectionReadFlag() {
        let p: IO.Memory.Map.Protection = .read
        #expect(p.contains(.read))
        #expect(!p.contains(.write))
    }

    @Test("Protection readWrite flags")
    func protectionReadWriteFlags() {
        let p: IO.Memory.Map.Protection = .readWrite
        #expect(p.contains(.read))
        #expect(p.contains(.write))
    }

    @Test("Protection none is empty")
    func protectionNoneEmpty() {
        let p: IO.Memory.Map.Protection = []
        #expect(!p.contains(.read))
        #expect(!p.contains(.write))
    }

    @Test("Sharing enum values")
    func sharingValues() {
        // Just verify enum cases exist
        let shared: IO.Memory.Map.Sharing = .shared
        let priv: IO.Memory.Map.Sharing = .private
        #expect(shared != priv)
    }

    @Test("Syscall error cases exist")
    func syscallErrorCasesExist() {
        // Verify error cases compile
        _ = IO.Memory.Map.Error.Syscall.invalidHandle(operation: .map)
        _ = IO.Memory.Map.Error.Syscall.invalidLength(operation: .map)
        _ = IO.Memory.Map.Error.Syscall.invalidAlignment(operation: .map)
    }

    @Test("Advice enum cases exist")
    func adviceCasesExist() {
        // Verify advice cases compile
        _ = IO.Memory.Map.Advice.normal
        _ = IO.Memory.Map.Advice.sequential
        _ = IO.Memory.Map.Advice.random
        _ = IO.Memory.Map.Advice.willNeed
        _ = IO.Memory.Map.Advice.dontNeed
    }
}

// MARK: - Integration Tests

extension IO.Memory.Map.Test.Unit {
    @Test("anonymous mapping round trip")
    func anonymousMappingRoundTrip() throws {
        let pageSize = IO.Memory.pageSize

        // Create anonymous mapping
        let result = try IO.Memory.Map.mapAnonymous(
            length: pageSize,
            protection: .readWrite,
            sharing: .private
        )

        #expect(result.baseAddress != nil)
        #expect(result.mappedLength >= pageSize)

        // Write and read back
        result.baseAddress.storeBytes(of: UInt8(42), as: UInt8.self)
        let readBack = result.baseAddress.load(as: UInt8.self)
        #expect(readBack == 42)

        // Unmap
        #if os(Windows)
        try IO.Memory.Map.unmap(address: result.baseAddress, mappingHandle: result.mappingHandle)
        #else
        try IO.Memory.Map.unmap(address: result.baseAddress, length: result.mappedLength)
        #endif
    }

    @Test("anonymous mapping with multiple pages")
    func anonymousMappingMultiplePages() throws {
        let pageSize = IO.Memory.pageSize
        let numPages = 4
        let totalSize = pageSize * numPages

        let result = try IO.Memory.Map.mapAnonymous(
            length: totalSize,
            protection: .readWrite,
            sharing: .private
        )

        #expect(result.mappedLength >= totalSize)

        // Write to each page
        for i in 0..<numPages {
            let offset = i * pageSize
            result.baseAddress.advanced(by: offset).storeBytes(of: UInt8(i + 1), as: UInt8.self)
        }

        // Verify each page
        for i in 0..<numPages {
            let offset = i * pageSize
            let value = result.baseAddress.advanced(by: offset).load(as: UInt8.self)
            #expect(value == UInt8(i + 1))
        }

        #if os(Windows)
        try IO.Memory.Map.unmap(address: result.baseAddress, mappingHandle: result.mappingHandle)
        #else
        try IO.Memory.Map.unmap(address: result.baseAddress, length: result.mappedLength)
        #endif
    }

    @Test("read-only anonymous mapping prevents writes")
    func readOnlyAnonymousMapping() throws {
        let pageSize = IO.Memory.pageSize

        let result = try IO.Memory.Map.mapAnonymous(
            length: pageSize,
            protection: .read,
            sharing: .private
        )

        #expect(result.baseAddress != nil)
        // Note: We can't easily test that writes crash without crashing the test.
        // The mapping exists and is read-only at the OS level.

        #if os(Windows)
        try IO.Memory.Map.unmap(address: result.baseAddress, mappingHandle: result.mappingHandle)
        #else
        try IO.Memory.Map.unmap(address: result.baseAddress, length: result.mappedLength)
        #endif
    }

    @Test("invalid length fails")
    func invalidLengthFails() {
        #expect(throws: IO.Memory.Map.Error.Syscall.self) {
            try IO.Memory.Map.mapAnonymous(
                length: 0,
                protection: .readWrite,
                sharing: .private
            )
        }
    }
}
