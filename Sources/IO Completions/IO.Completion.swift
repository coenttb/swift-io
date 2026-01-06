//
//  IO.Completion.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 31/12/2025.
//

@_exported public import IO_Primitives

extension IO {
    /// Namespace for completion-based I/O types.
    ///
    /// Provides a proactor-style completion-based I/O API:
    /// - **Windows**: IOCP (native)
    /// - **Linux**: io_uring (native, runtime detection)
    /// - **Darwin**: Not supported (use IO.Events with kqueue instead)
    ///
    /// Core principle: `submit operation → await completion`
    ///
    /// ## Architecture
    ///
    /// The completion-based I/O system is layered:
    /// 1. **Primitives** (this module): `Completion`, `ID`, `Operation`, `Event`, `Result`, `Error`
    /// 2. **Driver**: Protocol witness struct for platform backends
    /// 3. **Backends**: Platform-specific implementations (IOCP, io_uring)
    /// 4. **Runtime**: Queue actor, Bridge, Poll
    ///
    /// ## Key Types
    ///
    /// - `IO.Completion.ID`: Unique identifier for a submitted operation
    /// - `IO.Completion.Operation`: Move-only operation to be submitted
    /// - `IO.Completion.Event`: Completion event from the driver
    /// - `IO.Completion.Result`: Success/failure/cancelled result
    /// - `IO.Completion.Error`: Typed error hierarchy
    ///
    /// ## Thread Safety
    ///
    /// All primitive types are `Sendable`. Operations are `~Copyable` to
    /// enforce single-use semantics.
    public enum Completion {}
}
