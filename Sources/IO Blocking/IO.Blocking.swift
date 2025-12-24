//
//  IO.Blocking.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 24/12/2025.
//

public import IO_Primitives

extension IO {
    /// Namespace for blocking I/O lane abstractions.
    ///
    /// Contains the `Lane` protocol witness and default `Threads` implementation
    /// for running blocking syscalls without starving Swift's cooperative pool.
    public enum Blocking {}
}
