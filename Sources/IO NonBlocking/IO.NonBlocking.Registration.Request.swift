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
    /// ## Single Resumption Funnel
    /// Requests carry only a `ReplyID`, not a continuation. The poll thread
    /// pushes replies via `Reply.Bridge`, and the selector resumes the stored
    /// continuation on its executor. This ensures all continuations are resumed
    /// on the correct executor.
    ///
    /// ## Typed Errors
    /// All errors use `IO.NonBlocking.Error` (the leaf error type).
    /// Lifecycle errors (shutdown, cancellation) are handled by the selector.
    public enum Request: Sendable {
        /// Register a new descriptor.
        case register(
            descriptor: Int32,
            interest: IO.NonBlocking.Interest,
            replyID: ReplyID
        )

        /// Modify an existing registration.
        case modify(
            id: IO.NonBlocking.ID,
            interest: IO.NonBlocking.Interest,
            replyID: ReplyID
        )

        /// Deregister a descriptor.
        ///
        /// The reply ID is optional to support fire-and-forget
        /// deregistration during shutdown.
        case deregister(
            id: IO.NonBlocking.ID,
            replyID: ReplyID?
        )

        /// Arm a registration for readiness notification.
        ///
        /// This enables the kernel filter for the specified interest.
        /// With one-shot semantics (EV_DISPATCH on kqueue, EPOLLONESHOT on epoll),
        /// the filter is automatically disabled after delivering an event.
        ///
        /// Fire-and-forget: no reply needed. The selector has already
        /// created a waiter; the poll thread enables the kernel interest.
        case arm(
            id: IO.NonBlocking.ID,
            interest: IO.NonBlocking.Interest
        )
    }
}
