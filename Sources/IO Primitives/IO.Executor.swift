//
//  IO.Executor.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 28/12/2025.
//

extension IO {
    /// Namespace for executor types.
    ///
    /// Provides infrastructure for custom actor executors:
    /// - `Thread`: Single-threaded serial executor
    /// - `Threads`: Sharded pool of executor threads
    public enum Executor {}
}
