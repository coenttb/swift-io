//
//  IO.Executor.Handle.Entry.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 24/12/2025.
//

import Synchronization

extension IO.Executor.Handle {
    /// Internal entry in the handle registry.
    ///
    /// Uses a class to hold the non-copyable Resource.
    /// Actor isolation ensures thread safety without @unchecked Sendable.
    ///
    /// Generic over `Resource` which must be `~Copyable & Sendable`.
    internal final class Entry<Resource: ~Copyable & Sendable> {
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

        #if DEBUG
            /// Debug-only single-writer tripwire for entry mutation.
            ///
            /// This detects concurrent mutation of struct-on-class fields (e.g. `waiters`)
            /// which would otherwise manifest as ring-buffer corruption.
            private let _mutationDepth = Mutex<Int>(0)
        #endif

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
    }
}

// MARK: - Debug Mutation Tracking

#if DEBUG
    extension IO.Executor.Handle.Entry {
        /// Marks entry mutation scope; traps if concurrent mutation is detected.
        public func _debugBeginMutation() {
            _mutationDepth.withLock { depth in
                depth += 1
                precondition(depth == 1, "Concurrent Entry mutation detected")
            }
        }

        /// Ends entry mutation scope.
        public func _debugEndMutation() {
            _mutationDepth.withLock { depth in
                depth -= 1
                precondition(depth == 0, "Entry mutation scope imbalance")
            }
        }
    }
#endif

// MARK: - Properties

extension IO.Executor.Handle.Entry {
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
}

// MARK: - Resource Access

extension IO.Executor.Handle.Entry {
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
