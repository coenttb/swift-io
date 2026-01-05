//
//  IO.Backpressure.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 24/12/2025.
//

extension IO {
    /// Namespace for backpressure configuration.
    ///
    /// Backpressure controls how the system behaves when queues reach capacity.
    /// This unified configuration applies consistently across layers while
    /// allowing separate numeric limits for different queue types.
    public enum Backpressure {}
}
