//
//  IO.Executor.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 24/12/2025.
//

extension IO {
    /// Namespace for executor-related types that don't depend on Resource.
    public enum Executor {
        /// Global counter for generating unique scope IDs across all Pool instances.
        static let scopeCounter = IO.Blocking.Threads.Counter()
    }
}
