//
//  IO.Memory+PageSize.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 30/12/2025.
//

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#elseif os(Windows)
    import WinSDK
#endif

// MARK: - Public API

extension IO.Memory {
    /// Returns the system page size.
    ///
    /// - POSIX: `sysconf(_SC_PAGESIZE)` or `getpagesize()`
    /// - Windows: `SYSTEM_INFO.dwPageSize`
    public static var pageSize: Int {
        #if os(Windows)
            var info = SYSTEM_INFO()
            GetSystemInfo(&info)
            return Int(info.dwPageSize)
        #else
            let size = sysconf(Int32(_SC_PAGESIZE))
            return size > 0 ? Int(size) : 4096
        #endif
    }

    /// Returns the allocation granularity.
    ///
    /// - POSIX: Same as page size
    /// - Windows: `SYSTEM_INFO.dwAllocationGranularity` (typically 64KB)
    ///
    /// Memory mapping offsets must be aligned to this value.
    public static var granularity: Int {
        #if os(Windows)
            var info = SYSTEM_INFO()
            GetSystemInfo(&info)
            return Int(info.dwAllocationGranularity)
        #else
            // POSIX only requires page alignment
            return pageSize
        #endif
    }
}

// MARK: - Internal Alignment Helpers

extension IO.Memory {
    /// Aligns an offset down to allocation granularity.
    package static func alignOffsetDown(_ offset: Int) -> Int {
        let g = granularity
        return (offset / g) * g
    }

    /// Aligns a length up to page size.
    package static func alignLengthUp(_ length: Int) -> Int {
        let ps = pageSize
        return ((length + ps - 1) / ps) * ps
    }

    /// Calculates the delta between requested offset and aligned offset.
    package static func offsetDelta(for requestedOffset: Int) -> Int {
        requestedOffset - alignOffsetDown(requestedOffset)
    }
}
