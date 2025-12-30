//
//  IO.File.Descriptor.swift
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

extension IO.File {
    /// Platform-specific file descriptor type.
    ///
    /// - POSIX (Darwin, Linux): `Int32` (file descriptor)
    /// - Windows: `HANDLE`
    #if os(Windows)
    public typealias Descriptor = HANDLE
    #else
    public typealias Descriptor = Int32
    #endif

    /// Invalid descriptor sentinel value.
    #if os(Windows)
    public static let invalidDescriptor: Descriptor = INVALID_HANDLE_VALUE
    #else
    public static let invalidDescriptor: Descriptor = -1
    #endif
}
