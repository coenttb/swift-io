//
//  IO.Event.Selector.Make.Error.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 28/12/2025.
//

extension IO.Event.Selector.Make {
    /// Errors that can occur during selector construction.
    ///
    /// This is a construction-specific error type, separate from runtime
    /// I/O errors (`IO.Event.Error`) and lifecycle errors (`Failure`).
    public enum Error: Swift.Error, Sendable {
        /// Driver failed to create handle or wakeup channel.
        case driver(IO.Event.Error)
    }
}

extension IO.Event.Selector.Make.Error {
    /// Typed conversion helper for driver operations.
    ///
    /// Converts `throws(IO.Event.Error)` to `throws(Make.Error)`
    /// without existential widening or `as` casts in catch clauses.
    @inline(__always)
    static func driver<T: ~Copyable>(
        _ body: () throws(IO.Event.Error) -> T
    ) throws(IO.Event.Selector.Make.Error) -> T {
        do { return try body() } catch let e { throw .driver(e) }
    }
}
