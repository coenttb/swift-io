//
//  IO.Blocking.Threads.Runtime.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 24/12/2025.
//

extension IO.Blocking.Threads {
    /// Mutable runtime state for the Threads lane.
    // Safety Invariant (for @unchecked Sendable):
    // - state is thread-safe via its internal lock
    // - threads is only mutated in start() before any concurrent access
    // - isStarted and threads mutations are synchronized via state.lock
    final class Runtime: @unchecked Sendable {
        let state: Thread.Worker.State
        var threads: Threads = Threads()
        private(set) var deadlineManagerThread: Thread.Handle?
        private(set) var isStarted: Bool = false
        let options: Options

        init(options: Options) {
            self.options = options
            self.state = Thread.Worker.State(
                queueLimit: options.queueLimit,
                acceptanceWaitersLimit: options.acceptanceWaitersLimit
            )
        }

        func startIfNeeded() {
            state.lock.lock()
            defer { state.lock.unlock() }

            guard !isStarted else { return }
            isStarted = true

            // Start worker threads
            for i in 0..<options.workers {
                let worker = Thread.Worker(id: i, state: state)
                let handle = Thread.spawn {
                    worker.run()
                }
                threads.append(handle)
            }

            // Start deadline manager thread
            let deadlineManager = Deadline.Manager(state: state)
            deadlineManagerThread = Thread.spawn {
                deadlineManager.run()
            }
        }

        /// Joins all worker threads and the deadline manager.
        func joinAll() {
            threads.joinAll()
            if let managerThread = deadlineManagerThread {
                managerThread.join()
                deadlineManagerThread = nil
            }
        }
    }
}

// MARK: - Runtime.Threads

extension IO.Blocking.Threads.Runtime {
    /// Collection of worker thread handles with lifecycle operations.
    struct Threads {
        private(set) var handles: [IO.Blocking.Threads.Thread.Handle] = []

        /// Appends a thread handle.
        mutating func append(_ handle: IO.Blocking.Threads.Thread.Handle) {
            handles.append(handle)
        }

        /// Joins all threads and clears the collection.
        mutating func joinAll() {
            for thread in handles {
                thread.join()
            }
            handles.removeAll()
        }
    }
}
