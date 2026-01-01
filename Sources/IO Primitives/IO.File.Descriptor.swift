//
//  IO.File.Descriptor.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 30/12/2025.
//

public import Kernel

extension IO.File {
    /// Platform-specific file descriptor type.
    ///
    /// This is an alias for `Kernel.Descriptor`, which wraps:
    /// - POSIX (Darwin, Linux): `Int32` (file descriptor)
    /// - Windows: `HANDLE`
    public typealias Descriptor = Kernel.Descriptor

    /// Invalid descriptor sentinel value.
    public static let invalidDescriptor: Descriptor = .invalid
}
