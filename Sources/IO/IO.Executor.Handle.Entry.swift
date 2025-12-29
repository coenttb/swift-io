//
//  IO.Executor.Handle.Entry.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 24/12/2025.
//

extension IO.Executor.Handle {
    /// Internal entry in the handle registry.
    ///
    /// Uses a class to hold the non-copyable Resource.
    /// Actor isolation ensures thread safety without @unchecked Sendable.
    ///
    /// Generic over `Resource` which must be `~Copyable & Sendable`.
    public final class Entry<Resource: ~Copyable & Sendable> {
        /// The resource, or nil if currently checked out, reserved, or destroyed.
        public var handle: Resource?

        /// The resource when reserved for a specific waiter.
        ///
        /// Separated from `handle` to distinguish between:
        /// - `handle`: Available for immediate checkout
        /// - `reservedHandle`: Committed to a specific waiter by token
        public var reservedHandle: Resource?

        /// Queue of tasks waiting for this handle.
        public var waiters: IO.Handle.Waiters

        /// Current lifecycle state.
        public var state: State

        /// Creates an entry with the given resource and waiter capacity.
        ///
        /// - Parameters:
        ///   - handle: The resource to store (ownership transferred).
        ///   - waitersCapacity: Maximum waiters for this handle (default: 64).
        public init(handle: consuming Resource, waitersCapacity: Int = IO.Handle.Waiters.defaultCapacity) {
            self.handle = consume handle
            self.reservedHandle = nil
            self.waiters = IO.Handle.Waiters(capacity: waitersCapacity)
            self.state = .present
        }

        /// Whether the handle is logically open (present, checked out, or reserved).
        public var isOpen: Bool {
            switch state {
            case .present, .checkedOut, .reserved:
                return true
            case .destroyed:
                return false
            }
        }

        /// Whether destroy has been requested.
        public var isDestroyed: Bool {
            state == .destroyed
        }

        /// Takes the handle out if present, leaving nil.
        public func take() -> Resource? {
            guard state == .present else { return nil }
            guard handle != nil else { return nil }
            var result: Resource? = nil
            swap(&result, &handle)
            return result
        }

        /// Takes the reserved handle for a specific waiter token.
        ///
        /// - Parameter token: The waiter token that must match the reservation.
        /// - Returns: The reserved resource if token matches, nil otherwise.
        public func takeReserved(token: UInt64) -> Resource? {
            guard case .reserved(let reservedToken) = state, reservedToken == token else {
                return nil
            }
            guard reservedHandle != nil else { return nil }
            var result: Resource? = nil
            swap(&result, &reservedHandle)
            return result
        }
    }
}
