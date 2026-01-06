//
//  IO.Event.Deadline.Entry.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 30/12/2025.
//

extension IO.Event {
    /// Namespace for deadline scheduling types.
    public enum DeadlineScheduling {}
}

extension IO.Event.DeadlineScheduling {
    /// An entry in the deadline heap.
    ///
    /// Entries are compared by deadline. The generation field enables
    /// stale entry detection without requiring heap deletion.
    struct Entry: Sendable {
        /// The deadline timestamp in nanoseconds.
        let deadline: UInt64

        /// The key identifying the waiter.
        let key: IO.Event.Selector.PermitKey

        /// The generation at insertion time.
        ///
        /// If this doesn't match the current generation for this key,
        /// the entry is stale and should be skipped.
        let generation: UInt64
    }
}

extension IO.Event.DeadlineScheduling.Entry: Comparable {
    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.deadline < rhs.deadline
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.deadline == rhs.deadline && lhs.key == rhs.key && lhs.generation == rhs.generation
    }
}
