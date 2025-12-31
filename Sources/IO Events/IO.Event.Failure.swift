//
//  IO.Event.Failure.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 29/12/2025.
//

extension IO.Event {
    /// Canonical failure type for non-blocking I/O operations.
    ///
    /// This typealias standardizes the error type across all internal and public
    /// APIs. All continuations, async functions, and typed throws should use this
    /// type instead of `any Swift.Error`.
    ///
    /// ## Usage
    /// ```swift
    /// func operation() async throws(Failure) -> T
    /// CheckedContinuation<T, Failure>
    /// ```
    public typealias Failure = IO.Lifecycle.Error<Error>
}
