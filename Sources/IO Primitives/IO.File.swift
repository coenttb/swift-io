//
//  IO.File.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 30/12/2025.
//

public import Kernel

extension IO {
    /// File operations namespace.
    public enum File {}
}

extension IO.File {
    /// High-level file cloning operations.
    ///
    /// Low-level syscalls are in `Kernel.File.Clone`.
    /// This namespace provides orchestration and fallback logic.
    public enum Clone {}
}
