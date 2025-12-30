//
//  IO.Memory Tests.swift
//  swift-io
//

import StandardsTestSupport
import Testing

@testable import IO_Primitives

extension IO.Memory {
    #TestSuites
}

// MARK: - Unit Tests

extension IO.Memory.Test.Unit {
    @Test("pageSize is positive")
    func pageSizePositive() {
        #expect(IO.Memory.pageSize >= 1)
    }

    @Test("pageSize is a power of two")
    func pageSizePowerOfTwo() {
        let ps = IO.Memory.pageSize
        #expect(ps > 0)
        #expect((ps & (ps - 1)) == 0)
    }

    @Test("pageSize is reasonable")
    func pageSizeReasonable() {
        let ps = IO.Memory.pageSize
        // Page size should be at least 4KB and at most 64KB for most systems
        #expect(ps >= 4096)
        #expect(ps <= 65536)
    }

    @Test("granularity is positive")
    func granularityPositive() {
        #expect(IO.Memory.granularity >= 1)
    }

    @Test("granularity is a power of two")
    func granularityPowerOfTwo() {
        let g = IO.Memory.granularity
        #expect(g > 0)
        #expect((g & (g - 1)) == 0)
    }

    @Test("granularity >= pageSize")
    func granularityAtLeastPageSize() {
        #expect(IO.Memory.granularity >= IO.Memory.pageSize)
    }

    @Test("alignOffsetDown aligns correctly")
    func alignOffsetDownCorrect() {
        let granularity = IO.Memory.granularity

        // Zero stays zero
        #expect(IO.Memory.alignOffsetDown(0) == 0)

        // Aligned stays aligned
        #expect(IO.Memory.alignOffsetDown(granularity) == granularity)
        #expect(IO.Memory.alignOffsetDown(granularity * 2) == granularity * 2)

        // Unaligned rounds down
        #expect(IO.Memory.alignOffsetDown(1) == 0)
        #expect(IO.Memory.alignOffsetDown(granularity - 1) == 0)
        #expect(IO.Memory.alignOffsetDown(granularity + 1) == granularity)
    }

    @Test("alignLengthUp aligns correctly")
    func alignLengthUpCorrect() {
        let pageSize = IO.Memory.pageSize

        // Zero stays zero
        #expect(IO.Memory.alignLengthUp(0) == 0)

        // Aligned stays aligned
        #expect(IO.Memory.alignLengthUp(pageSize) == pageSize)
        #expect(IO.Memory.alignLengthUp(pageSize * 2) == pageSize * 2)

        // Unaligned rounds up
        #expect(IO.Memory.alignLengthUp(1) == pageSize)
        #expect(IO.Memory.alignLengthUp(pageSize - 1) == pageSize)
        #expect(IO.Memory.alignLengthUp(pageSize + 1) == pageSize * 2)
    }

    @Test("offsetDelta calculates correctly")
    func offsetDeltaCorrect() {
        let granularity = IO.Memory.granularity

        // Aligned offset has zero delta
        #expect(IO.Memory.offsetDelta(for: 0) == 0)
        #expect(IO.Memory.offsetDelta(for: granularity) == 0)

        // Unaligned offset has non-zero delta
        #expect(IO.Memory.offsetDelta(for: 1) == 1)
        #expect(IO.Memory.offsetDelta(for: granularity - 1) == granularity - 1)
        #expect(IO.Memory.offsetDelta(for: granularity + 1) == 1)
    }
}
