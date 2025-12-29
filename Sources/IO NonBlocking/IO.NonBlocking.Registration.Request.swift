//
//  IO.NonBlocking.Registration.Request.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 28/12/2025.
//

extension IO.NonBlocking.Registration {
    /// A request from the selector to the poll thread.
    ///
    /// These requests are enqueued by the selector actor and processed
    /// by the poll thread between poll cycles.
    ///
    /// ## Typed Errors
    /// All continuations use `IO.NonBlocking.Error` (the leaf error type)
    /// rather than `any Swift.Error`. Lifecycle errors (shutdown, cancellation)
    /// are handled by the selector, not the poll thread.
    public enum Request: Sendable {
        /// Register a new descriptor.
        case register(
            descriptor: Int32,
            interest: IO.NonBlocking.Interest,
            continuation: CheckedContinuation<Result<IO.NonBlocking.ID, IO.NonBlocking.Error>, Never>
        )

        /// Modify an existing registration.
        case modify(
            id: IO.NonBlocking.ID,
            interest: IO.NonBlocking.Interest,
            continuation: CheckedContinuation<Result<Void, IO.NonBlocking.Error>, Never>
        )

        /// Deregister a descriptor.
        ///
        /// The continuation is optional to support fire-and-forget
        /// deregistration during shutdown.
        case deregister(
            id: IO.NonBlocking.ID,
            continuation: CheckedContinuation<Result<Void, IO.NonBlocking.Error>, Never>?
        )
    }
}
