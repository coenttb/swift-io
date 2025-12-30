//
//  IO.Memory.Map.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 30/12/2025.
//

extension IO.Memory {
    /// Namespace for memory mapping operations.
    ///
    /// Contains:
    /// - `Platform`: Low-level syscall wrappers (mmap/munmap/msync)
    /// - `Region`: High-level ~Copyable mapped region (in IO module)
    /// - `Error`: Semantic error types (in IO module)
    public enum Map {}
}
