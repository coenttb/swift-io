//
//  IO.Lifecycle.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 28/12/2025.
//

public import Synchronization

extension IO {
    /// Lifecycle state for Pool and Lane operations.
    ///
    /// This enum enables atomic lifecycle checks without actor isolation,
    /// allowing `run()` to bypass the actor hop for improved throughput.
    ///
    /// ## Memory Ordering
    /// - Readers use `.acquiring` to see effects of shutdown
    /// - Writers use `.releasing` to publish state changes
    public enum Lifecycle: UInt8, Sendable, AtomicRepresentable {
        /// Running and accepting new work.
        case running = 0
        /// Shutdown has been initiated; new work is rejected.
        case shutdownInProgress = 1
        /// Shutdown is complete; resources are torn down.
        case shutdownComplete = 2
    }
}
