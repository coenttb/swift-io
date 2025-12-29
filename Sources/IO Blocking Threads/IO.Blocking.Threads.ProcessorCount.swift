//
//  IO.Blocking.Threads.ProcessorCount.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 24/12/2025.
//

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#elseif os(Windows)
    import WinSDK
#endif

extension IO.Blocking.Threads {
    /// Returns the number of active processors.
    static var processorCount: Int {
        #if canImport(Darwin)
            return Int(sysconf(_SC_NPROCESSORS_ONLN))
        #elseif canImport(Glibc)
            return Int(sysconf(Int32(_SC_NPROCESSORS_ONLN)))
        #elseif os(Windows)
            return Int(GetActiveProcessorCount(WORD(ALL_PROCESSOR_GROUPS)))
        #else
            return 4
        #endif
    }
}
