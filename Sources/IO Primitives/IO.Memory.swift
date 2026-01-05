//
//  IO.Memory.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 30/12/2025.
//

extension IO {
    /// Namespace for memory operations.
    ///
    /// Memory-related types have moved to dedicated packages:
    /// - Memory mapping: Use `Memory.Map` from swift-memory
    /// - Aligned buffers: Use `Buffer.Aligned` from swift-buffer
    /// - Page size: Use `Kernel.System.pageSize` from swift-kernel
    public enum Memory {}
}
