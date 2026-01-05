//
//  IO.Blocking.Threads.DebugSnapshot.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 24/12/2025.
//

extension IO.Blocking.Threads {
    /// Snapshot of internal state for testing.
    public struct DebugSnapshot: Sendable {
        public let sleepers: Int
        public let queueIsEmpty: Bool
        public let queueCount: Int
        public let inFlightCount: Int
        public let isShutdown: Bool
    }
}
