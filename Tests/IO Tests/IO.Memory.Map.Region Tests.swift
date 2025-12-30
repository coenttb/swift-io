//
//  IO.Memory.Map.Region Tests.swift
//  swift-io
//

import StandardsTestSupport
import Testing

@testable import IO
@testable import IO_Primitives

extension IO.Memory.Map.Region {
    #TestSuites
}

// MARK: - Unit Tests

extension IO.Memory.Map.Region.Test.Unit {
    // MARK: - Access enum tests

    @Test("Access.read allows read")
    func accessReadAllowsRead() {
        let access: IO.Memory.Map.Region.Access = .read
        #expect(access.allowsRead)
        #expect(!access.allowsWrite)
    }

    @Test("Access.readWrite allows both")
    func accessReadWriteAllowsBoth() {
        let access: IO.Memory.Map.Region.Access = .readWrite
        #expect(access.allowsRead)
        #expect(access.allowsWrite)
    }

    @Test("Access.copyOnWrite allows both")
    func accessCopyOnWriteAllowsBoth() {
        let access: IO.Memory.Map.Region.Access = .copyOnWrite
        #expect(access.allowsRead)
        #expect(access.allowsWrite)
    }

    // MARK: - Sharing enum tests

    @Test("Sharing values are distinct")
    func sharingValuesDistinct() {
        let shared: IO.Memory.Map.Region.Sharing = .shared
        let priv: IO.Memory.Map.Region.Sharing = .private
        #expect(shared != priv)
    }

    // MARK: - Range enum tests

    @Test("Range.bytes stores offset and length")
    func rangeBytesValues() {
        let range: IO.Memory.Map.Region.Range = .bytes(offset: 1024, length: 4096)
        #expect(range.offset == 1024)
        #expect(range.length == 4096)
    }

    @Test("Range.wholeFile has zero offset and nil length")
    func rangeWholeFileOffset() {
        let range: IO.Memory.Map.Region.Range = .wholeFile
        #expect(range.offset == 0)
        #expect(range.length == nil, ".wholeFile length is nil until resolved at map time")
    }

    // MARK: - Safety enum tests

    @Test("Safety.unchecked exists")
    func safetyUncheckedExists() {
        let safety: IO.Memory.Map.Region.Safety = .unchecked
        if case .unchecked = safety {
            // Expected
        } else {
            Issue.record("Expected unchecked case")
        }
    }

    @Test("Safety.coordinated stores mode and scope")
    func safetyCoordinatedValues() {
        let safety: IO.Memory.Map.Region.Safety = .coordinated(.exclusive, scope: .wholeFile)
        if case .coordinated(let mode, let scope) = safety {
            #expect(mode == .exclusive)
            #expect(scope == .wholeFile)
        } else {
            Issue.record("Expected coordinated case")
        }
    }

    @Test("Safety defaults for read")
    func safetyDefaultForRead() {
        let safety = IO.Memory.Map.Region.Safety.defaultForRead
        if case .coordinated(let mode, let scope) = safety {
            #expect(mode == .shared)
            #expect(scope == .mappedRange)
        } else {
            Issue.record("Expected coordinated case")
        }
    }

    @Test("Safety defaults for write")
    func safetyDefaultForWrite() {
        let safety = IO.Memory.Map.Region.Safety.defaultForWrite
        if case .coordinated(let mode, let scope) = safety {
            #expect(mode == .exclusive)
            #expect(scope == .mappedRange)
        } else {
            Issue.record("Expected coordinated case")
        }
    }
}

// MARK: - Integration Tests

extension IO.Memory.Map.Region.Test.Unit {
    @Test("anonymous mapping creation and access")
    func anonymousMappingCreation() throws {
        var region = try IO.Memory.Map.Region(
            anonymousLength: 4096,
            access: .readWrite,
            sharing: .private
        )

        // Extract values before #expect (workaround for ~Copyable)
        let isMapped = region.isMapped
        let length = region.length
        let access = region.access
        let sharing = region.sharing
        let hasBase = region.baseAddress != nil
        let hasMutableBase = region.mutableBaseAddress != nil

        #expect(isMapped)
        #expect(length == 4096)
        #expect(access == .readWrite)
        #expect(sharing == .private)
        #expect(hasBase)
        #expect(hasMutableBase)

        region.unmap()
    }

    @Test("anonymous mapping write and read")
    func anonymousMappingWriteRead() throws {
        var region = try IO.Memory.Map.Region(
            anonymousLength: 4096,
            access: .readWrite,
            sharing: .private
        )

        // Write via write method
        region.write(42, at: 0)
        region.write(255, at: 100)

        // Read via subscript, extract values
        let v0 = region[0]
        let v100 = region[100]

        #expect(v0 == 42)
        #expect(v100 == 255)

        region.unmap()
    }

    @Test("anonymous mapping withUnsafeBytes")
    func anonymousMappingWithUnsafeBytes() throws {
        var region = try IO.Memory.Map.Region(
            anonymousLength: 4096,
            access: .readWrite,
            sharing: .private
        )

        region.write(42, at: 0)

        let result = region.withUnsafeBytes { buffer in
            buffer[0]
        }
        #expect(result == 42)

        region.unmap()
    }

    @Test("anonymous mapping withUnsafeMutableBytes")
    func anonymousMappingWithUnsafeMutableBytes() throws {
        var region = try IO.Memory.Map.Region(
            anonymousLength: 4096,
            access: .readWrite,
            sharing: .private
        )

        region.withUnsafeMutableBytes { buffer in
            buffer[0] = 123
        }

        let v0 = region[0]
        #expect(v0 == 123)

        region.unmap()
    }

    @Test("read-only mapping has no mutableBaseAddress")
    func readOnlyNoMutableAddress() throws {
        var region = try IO.Memory.Map.Region(
            anonymousLength: 4096,
            access: .read,
            sharing: .private
        )

        let hasBase = region.baseAddress != nil
        let hasMutableBase = region.mutableBaseAddress != nil

        #expect(hasBase)
        #expect(!hasMutableBase)

        region.unmap()
    }

    @Test("debugDescription includes key info")
    func debugDescriptionContent() throws {
        var region = try IO.Memory.Map.Region(
            anonymousLength: 4096,
            access: .readWrite,
            sharing: .private
        )

        let desc = region.debugDescription
        #expect(desc.contains("mapped"))
        #expect(desc.contains("4096"))
        #expect(desc.contains("readWrite"))

        region.unmap()
    }

    @Test("multiple anonymous mappings are independent")
    func multipleIndependentMappings() throws {
        var region1 = try IO.Memory.Map.Region(
            anonymousLength: 4096,
            access: .readWrite,
            sharing: .private
        )
        var region2 = try IO.Memory.Map.Region(
            anonymousLength: 4096,
            access: .readWrite,
            sharing: .private
        )

        // Write different values
        region1.write(1, at: 0)
        region2.write(2, at: 0)

        // Verify independence - extract values
        let v1 = region1[0]
        let v2 = region2[0]

        #expect(v1 == 1)
        #expect(v2 == 2)

        region1.unmap()
        region2.unmap()
    }

    @Test("large anonymous mapping")
    func largeAnonymousMapping() throws {
        let size = 1024 * 1024  // 1 MB
        var region = try IO.Memory.Map.Region(
            anonymousLength: size,
            access: .readWrite,
            sharing: .private
        )

        let length = region.length
        #expect(length == size)

        // Write to different positions
        region.write(1, at: 0)
        region.write(2, at: size / 2)
        region.write(3, at: size - 1)

        let v0 = region[0]
        let vMid = region[size / 2]
        let vEnd = region[size - 1]

        #expect(v0 == 1)
        #expect(vMid == 2)
        #expect(vEnd == 3)

        region.unmap()
    }
}
