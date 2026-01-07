//
//  IO.Failure.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 07/01/2026.
//

// MARK: - Failure Namespace

extension IO {
    /// Namespace for typed error composition envelopes.
    ///
    /// ## Overview
    ///
    /// IO provides stable composition envelopes that carry domain errors:
    /// - `IO.Failure.Work<Domain, Operation>` for `IO.run` with throwing operations
    /// - `IO.Failure.Scope<Domain, Create, Body, Close>` for `IO.open` scoped operations
    ///
    /// Domains own their lifecycle errors:
    /// - `IO.Lane.Error` owns lane lifecycle (cancelled, timeout, shutdown, overloaded)
    /// - `IO.Pool.Error` owns pool lifecycle (shutdown, exhausted, timeout, cancelled)
    ///
    /// ## Design Rationale
    ///
    /// By having domains own their errors and IO provide only envelopes:
    /// - Domains can evolve independently (add `.workerDied`, `.ringReset`, etc.)
    /// - No "shared vocabulary committee" problem
    /// - Still 100% typed throws at call site
    /// - Clean pattern matching
    public enum Failure {}
}

// MARK: - Work Envelope

extension IO.Failure {
    /// Error envelope for `IO.run` with throwing operations.
    ///
    /// ## Usage
    ///
    /// ```swift
    /// do {
    ///     let value = try await IO.run(deadline: .after(.seconds(5))) {
    ///         try socket.connect()
    ///     }
    /// } catch {
    ///     switch error {
    ///     case .domain(.timeout): // handle timeout
    ///     case .domain(.cancelled): // handle cancellation
    ///     case .operation(let e): // handle socket error
    ///     }
    /// }
    /// ```
    ///
    /// ## Design
    ///
    /// - `Domain`: Lane infrastructure errors (typically `IO.Lane.Error`)
    /// - `Operation`: User's operation error type
    public enum Work<
        Domain: Swift.Error & Sendable,
        Operation: Swift.Error & Sendable
    >: Swift.Error, Sendable {
        /// Lane infrastructure failed (timeout, cancelled, shutdown, overloaded).
        case domain(Domain)

        /// The operation threw an error.
        case operation(Operation)
    }
}

// MARK: - Work Equatable

extension IO.Failure.Work: Equatable where Domain: Equatable, Operation: Equatable {}

// MARK: - Work CustomStringConvertible

extension IO.Failure.Work: CustomStringConvertible {
    public var description: String {
        switch self {
        case .domain(let error):
            "domain(\(error))"
        case .operation(let error):
            "operation(\(error))"
        }
    }
}

// MARK: - Scope Envelope

extension IO.Failure {
    /// Error envelope for `IO.open` scoped operations.
    ///
    /// ## Usage
    ///
    /// ```swift
    /// do {
    ///     try await IO.open { try File.open(path) } body: { file in
    ///         file.read(into: buffer)
    ///     }
    /// } catch {
    ///     switch error {
    ///     case .domain(.timeout): // lane timeout
    ///     case .create(let e): // file open failed
    ///     case .body(let e): // read failed
    ///     case .close(let e): // close failed
    ///     case .bodyAndClose(let body, let close): // both failed
    ///     }
    /// }
    /// ```
    ///
    /// ## Behavioral Invariants
    ///
    /// | Scenario | Result |
    /// |----------|--------|
    /// | Body throws, close succeeds | `.body(E)` |
    /// | Body succeeds, close throws | `.close(E)` |
    /// | Body throws, close throws | `.bodyAndClose(body: E, close: E)` |
    /// | Create throws | `.create(E)` - no close attempted |
    /// | Lane infrastructure fails | `.domain(E)` - nothing started |
    ///
    /// ## Design
    ///
    /// - `Domain`: Lane infrastructure errors (typically `IO.Lane.Error`)
    /// - `Create`: Error from resource creation
    /// - `Body`: Error from body execution
    /// - `Close`: Error from resource cleanup
    public enum Scope<
        Domain: Swift.Error & Sendable,
        Create: Swift.Error & Sendable,
        Body: Swift.Error & Sendable,
        Close: Swift.Error & Sendable
    >: Swift.Error, Sendable {
        /// Lane infrastructure failed before scope could execute.
        ///
        /// This occurs when the blocking lane is overloaded, timed out, etc.
        /// The scope never started - no resource was created.
        case domain(Domain)

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
    }
}

// MARK: - Scope Equatable

extension IO.Failure.Scope: Equatable where Domain: Equatable, Create: Equatable, Body: Equatable, Close: Equatable {}

// MARK: - Scope CustomStringConvertible

extension IO.Failure.Scope: CustomStringConvertible {
    public var description: String {
        switch self {
        case .domain(let error):
            "domain(\(error))"
        case .create(let error):
            "create(\(error))"
        case .body(let error):
            "body(\(error))"
        case .close(let error):
            "close(\(error))"
        case .bodyAndClose(let body, let close):
            "bodyAndClose(body: \(body), close: \(close))"
        }
    }
}
