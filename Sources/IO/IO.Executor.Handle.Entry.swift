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
        /// The resource, or nil if currently checked out or destroyed.
        public var handle: Resource?

        /// Queue of tasks waiting for this handle.
        public var waiters: IO.Handle.Waiters

        /// Current lifecycle state.
        public var state: State

        public init(handle: consuming Resource) {
            self.handle = consume handle
            self.waiters = IO.Handle.Waiters()
            self.state = .present
        }

        /// Whether the handle is logically open (present or checked out).
        public var isOpen: Bool {
            state == .present || state == .checkedOut
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
    }
}
