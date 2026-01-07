//
//  IO.Closure.Error.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 24/12/2025.
//

extension IO.Closure {
    /// Error wrapper for user-provided closure errors.
    ///
    /// Used with `IO.Error<IO.Closure.Error>` when the closure error type
    /// is unknown at compile time. The error description is captured as a string
    /// for Swift Embedded compatibility (avoids existential types).
    internal struct Error: Swift.Error, Sendable, Equatable, CustomStringConvertible {
        /// A description of the original error.
        internal let description: String

        /// Creates a closure error from any typed error.
        /// Generic version - no existentials.
        internal init<E: Swift.Error>(_ error: E) {
            self.description = String(describing: error)
        }

        /// Creates a closure error from a description.
        internal init(description: String) {
            self.description = description
        }
    }
}
