//
//  IO.Platform.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 28/12/2025.
//

public import Kernel

extension IO {
    /// Platform-specific utilities without Foundation dependency.
    public enum Platform {}
}

extension IO.Platform {
    /// Returns the number of available processors.
    ///
    /// Forwards to `Kernel.System.processorCount`.
    @inlinable
    public static var processorCount: Int {
        Kernel.System.processorCount
    }
}
