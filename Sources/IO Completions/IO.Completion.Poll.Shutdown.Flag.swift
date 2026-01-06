//
//  IO.Completion.Poll.Shutdown.Flag.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 31/12/2025.
//

public import Dimension
public import Kernel

extension IO.Completion.Poll.Shutdown {
    /// Atomic flag for signaling poll loop shutdown.
    ///
    /// Delegates to `Kernel.Atomic.Flag` for atomic boolean handling.
    /// Access underlying API via `.rawValue`.
    public typealias Flag = Tagged<IO.Completion.Poll.Shutdown, Kernel.Atomic.Flag>
}
