//
//  IO.Closable.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 07/01/2026.
//

extension IO {
    /// Protocol for resources that can be closed.
    ///
    /// ## Design
    ///
    /// This protocol enables automatic close inference for `lane.open`:
    /// ```swift
    /// // If File: IO.Closable with CloseError == Never
    /// try await lane.open { File.open(path) } { file in
    ///     file.read(into: buffer)
    /// }
    /// // close() called automatically
    /// ```
    ///
    /// ## ~Copyable Support
    ///
    /// The protocol supports non-copyable resources through `~Copyable` inheritance.
    /// The `consuming` modifier on `close()` ensures the resource cannot be used
    /// after closing.
    ///
    /// ## Error Typing
    ///
    /// `CloseError` defaults to `Never` for resources that cannot fail on close.
    /// This enables `Never` elimination in composed error types.
    public protocol Closable: ~Copyable {
        /// The error type that close can throw.
        ///
        /// Defaults to `Never` for infallible close operations.
        associatedtype CloseError: Swift.Error & Sendable = Never

        /// Close the resource, releasing any underlying handles.
        ///
        /// This method is `consuming` to prevent use-after-close at compile time.
        consuming func close() throws(CloseError)
    }
}
