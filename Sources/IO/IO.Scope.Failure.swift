//
//  IO.Scope.Failure.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 07/01/2026.
//

extension IO.Scope {
    /// Operational errors from scoped resource lifecycle.
    ///
    /// ## Design
    ///
    /// This three-generic error captures all failure modes in resource lifecycle:
    /// - `Create`: Error during resource acquisition
    /// - `Body`: Error during resource usage
    /// - `Close`: Error during resource cleanup
    ///
    /// ## Composition with IO.Lifecycle.Error
    ///
    /// This type is wrapped in `IO.Lifecycle.Error` for full typed throws:
    /// ```swift
    /// throws(IO.Lifecycle.Error<IO.Scope.Failure<CreateError, BodyError, CloseError>>)
    /// ```
    ///
    /// The outer wrapper handles shutdown/cancellation/timeout.
    /// This type handles operational failures.
    ///
    /// ## Behavioral Invariants
    ///
    /// | Scenario | Result |
    /// |----------|--------|
    /// | Body throws, close succeeds | `.body(E)` |
    /// | Body succeeds, close throws | `.close(E)` |
    /// | Body throws, close throws | `.bodyAndClose(body: E, close: E)` |
    /// | Create throws | `.create(E)` - no close attempted |
    ///
    /// ## Never Elimination
    ///
    /// When `Create`, `Body`, or `Close` is `Never`, that case becomes
    /// statically unreachable, enabling the compiler to eliminate branches.
    public enum Failure<
        Create: Swift.Error & Sendable,
        Body: Swift.Error & Sendable,
        Close: Swift.Error & Sendable
    >: Swift.Error, Sendable {
        /// Resource creation failed.
        ///
        /// Close is not called when create fails.
        case create(Create)

        /// Body execution failed, close succeeded.
        case body(Body)

        /// Body succeeded, close failed.
        case close(Close)

        /// Both body and close failed.
        ///
        /// Body error is primary; close error is preserved for diagnostics.
        case bodyAndClose(body: Body, close: Close)

        /// Lane infrastructure failed before scope could execute.
        ///
        /// This occurs when the blocking lane is overloaded or full.
        /// The scope never started - no resource was created.
        case lane(IO.Blocking.Lane.Error)
    }
}

// MARK: - Equatable

extension IO.Scope.Failure: Equatable where Create: Equatable, Body: Equatable, Close: Equatable {}

// MARK: - CustomStringConvertible

extension IO.Scope.Failure: CustomStringConvertible {
    public var description: String {
        switch self {
        case .create(let error):
            "create(\(error))"
        case .body(let error):
            "body(\(error))"
        case .close(let error):
            "close(\(error))"
        case .bodyAndClose(let body, let close):
            "bodyAndClose(body: \(body), close: \(close))"
        case .lane(let error):
            "lane(\(error))"
        }
    }
}
