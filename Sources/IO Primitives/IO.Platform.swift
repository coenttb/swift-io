//
//  IO.Platform.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 28/12/2025.
//

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif os(Windows)
import WinSDK
#endif

extension IO {
    /// Platform-specific utilities without Foundation dependency.
    public enum Platform {}
}

extension IO.Platform {
    /// Returns the number of available processors.
    ///
    /// Uses platform-native syscalls to avoid Foundation dependency:
    /// - POSIX (Darwin/Linux): `sysconf(_SC_NPROCESSORS_ONLN)`
    /// - Windows: `GetSystemInfo`
    public static var processorCount: Int {
        #if os(Windows)
        var info = SYSTEM_INFO()
        GetSystemInfo(&info)
        return Int(info.dwNumberOfProcessors)
        #else
        let count = sysconf(_SC_NPROCESSORS_ONLN)
        return count > 0 ? Int(count) : 1
        #endif
    }
}
