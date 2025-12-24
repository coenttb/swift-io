//
//  IO.Blocking.Failure.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 24/12/2025.
//

extension IO.Blocking {
    /// Infrastructure failures from the Lane itself.
    /// Operation errors are returned in the boxed Result, not thrown.
    public enum Failure: Swift.Error, Sendable, Equatable {
        case shutdown
        case queueFull
        case deadlineExceeded
        case cancelled
    }
}
