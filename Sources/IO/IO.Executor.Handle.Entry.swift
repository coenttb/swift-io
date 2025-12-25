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
    /// Generic over `Resource: ~Copyable` - Sendable is NOT required.
    final class Entry<Resource: ~Copyable> {
        /// The resource, or nil if currently checked out or destroyed.
        var resource: Resource?

        /// Queue of tasks waiting for this handle.
        var waiters: IO.Handle.Waiters

        /// Current lifecycle state.
        var state: State

        /// Creates an entry with the given resource and waiter capacity.
        ///
        /// - Parameters:
        ///   - resource: The resource to store (ownership transferred).
        ///   - waitersCapacity: Maximum waiters for this handle (default: 64).
        init(resource: consuming Resource, waitersCapacity: Int = IO.Handle.Waiters.defaultCapacity) {
            self.resource = consume resource
            self.waiters = IO.Handle.Waiters(capacity: waitersCapacity)
            self.state = .present
        }

        /// Whether the handle is logically open (present or checked out).
        var isOpen: Bool {
            state == .present || state == .checkedOut
        }

        /// Whether destroy has been requested.
        var isDestroyed: Bool {
            state == .destroyed
        }

        /// Returns the resource if present, leaving nil.
        func take() -> Resource? {
            guard state == .present else { return nil }
            guard resource != nil else { return nil }
            var result: Resource? = nil
            swap(&result, &resource)
            return result
        }
    }
}
