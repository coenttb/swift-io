//
//  IO.Blocking.Threads.Runtime.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 24/12/2025.
//


extension IO.Blocking.Threads {
    /// Mutable runtime state for the Threads lane.
    ///
    /// ## Safety Invariant (for @unchecked Sendable)
    /// - `state` is thread-safe via its internal lock
    /// - `threads` is only mutated in `start()` before any concurrent access
    /// - `isStarted` and `threads` mutations are synchronized via state.lock
    final class Runtime: @unchecked Sendable {
        let state: Thread.Worker.State
        private(set) var threads: [Thread.Handle] = []
        private(set) var isStarted: Bool = false
        let options: Options

        init(options: Options) {
            self.options = options
            self.state = Thread.Worker.State(queueLimit: options.queueLimit)
        }

        func startIfNeeded() {
            state.lock.lock()
            defer { state.lock.unlock() }

            guard !isStarted else { return }
            isStarted = true

            for i in 0..<options.workers {
                let worker = Thread.Worker(id: i, state: state)
                let handle = Thread.spawn {
                    worker.run()
                }
                threads.append(handle)
            }
        }

        func joinAllThreads() {
            for thread in threads {
                thread.join()
            }
            threads.removeAll()
        }
    }
}
