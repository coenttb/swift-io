//
//  IO.Event.Deadline.Heap.swift
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
        lhs.deadline == rhs.deadline &&
        lhs.key == rhs.key &&
        lhs.generation == rhs.generation
    }
}

extension IO.Event.DeadlineScheduling {
    /// A min-heap for deadline scheduling.
    ///
    /// This is a simple binary heap with O(log N) push and pop operations.
    /// Entries are ordered by deadline (earliest first).
    ///
    /// ## Stale Entry Handling
    /// The heap does not support efficient deletion. Instead, entries become
    /// "stale" when their generation doesn't match the current generation
    /// for that key. Stale entries are skipped during pop operations.
    struct MinHeap: Sendable {
        /// The underlying storage.
        private var storage: [Entry] = []

        /// Creates an empty heap.
        init() {}

        /// The number of entries in the heap (including potentially stale entries).
        var count: Int { storage.count }

        /// Whether the heap is empty.
        var isEmpty: Bool { storage.isEmpty }

        /// Returns the minimum entry without removing it.
        ///
        /// - Returns: The entry with the earliest deadline, or `nil` if empty.
        func peek() -> Entry? {
            storage.first
        }

        /// Adds an entry to the heap.
        ///
        /// - Parameter entry: The entry to add.
        /// - Complexity: O(log N)
        mutating func push(_ entry: Entry) {
            storage.append(entry)
            siftUp(from: storage.count - 1)
        }

        /// Removes and returns the minimum entry.
        ///
        /// - Returns: The entry with the earliest deadline, or `nil` if empty.
        /// - Complexity: O(log N)
        @discardableResult
        mutating func pop() -> Entry? {
            guard !storage.isEmpty else { return nil }

            if storage.count == 1 {
                return storage.removeLast()
            }

            let result = storage[0]
            storage[0] = storage.removeLast()
            siftDown(from: 0)
            return result
        }

        // MARK: - Heap Operations

        /// Restores heap property by moving an element up.
        private mutating func siftUp(from index: Int) {
            var child = index
            var parent = parentIndex(of: child)

            while child > 0 && storage[child] < storage[parent] {
                storage.swapAt(child, parent)
                child = parent
                parent = parentIndex(of: child)
            }
        }

        /// Restores heap property by moving an element down.
        private mutating func siftDown(from index: Int) {
            var parent = index

            while true {
                let left = leftChildIndex(of: parent)
                let right = rightChildIndex(of: parent)
                var smallest = parent

                if left < storage.count && storage[left] < storage[smallest] {
                    smallest = left
                }
                if right < storage.count && storage[right] < storage[smallest] {
                    smallest = right
                }

                if smallest == parent {
                    break
                }

                storage.swapAt(parent, smallest)
                parent = smallest
            }
        }

        // MARK: - Index Calculations

        private func parentIndex(of index: Int) -> Int {
            (index - 1) / 2
        }

        private func leftChildIndex(of index: Int) -> Int {
            2 * index + 1
        }

        private func rightChildIndex(of index: Int) -> Int {
            2 * index + 2
        }
    }
}
