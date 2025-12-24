//
//  IO.Handle.Error.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 24/12/2025.
//

extension IO.Handle {
    /// Errors related to handle operations in the executor.
    public enum Error: Swift.Error, Sendable, Equatable {
        /// The handle ID does not exist in the registry (already closed or never existed).
        case invalidID
        /// The handle ID belongs to a different executor.
        case scopeMismatch
        /// The handle has already been closed.
        case handleClosed
        /// The waiter queue for this handle is full (bounded memory protection).
        ///
        /// This is a HANDLE-LEVEL error indicating too many tasks are waiting
        /// for this specific handle. Distinct from lane-level `.overloaded`.
        /// Callers may retry with backoff.
        case waitersFull
    }
}
