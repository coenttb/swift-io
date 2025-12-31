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
    ///
    /// ## Thread Handle Storage
    /// Uses `Worker.Handle` reference wrappers to store ~Copyable
    /// `IO.Thread.Handle` values in arrays. The reference wrapper enforces
    /// exactly-once join semantics while allowing Copyable array storage.
    final class Runtime: @unchecked Sendable {
        let state: Worker.State
        private(set) var threads: [Worker.Handle] = []
        private(set) var deadlineManagerThread: Worker.Handle?
        private(set) var isStarted: Bool = false
        let options: Options

        init(options: Options) {
            self.options = options
            self.state = Worker.State(
                queueLimit: options.queueLimit,
                acceptanceWaitersLimit: options.acceptanceWaitersLimit
            )
        }

        func start(ifNeeded: Void = ()) {
            state.lock.lock()
            defer { state.lock.unlock() }

            guard !isStarted else { return }
            isStarted = true

            // Start worker threads
            // Thread creation failure is catastrophic - we use IO.Thread.trap
            // since the lane cannot function without its worker threads.
            for i in 0..<options.workers {
                let worker = Worker(id: i, state: state)
                let handle = IO.Thread.trap {
                    worker.run()
                }
                threads.append(Worker.Handle(handle))
            }

            // Start deadline manager thread
            let deadlineManager = Deadline.Manager(state: state)
            let handle = IO.Thread.trap {
                deadlineManager.run()
            }
            deadlineManagerThread = Worker.Handle(handle)
        }

        func joinAllThreads() {
            // Join worker threads - each join() consumes the inner handle exactly once
            for thread in threads {
                thread.join()
            }
            threads.removeAll()

            // Join deadline manager
            if let managerThread = deadlineManagerThread {
                managerThread.join()
                deadlineManagerThread = nil
            }
        }
    }
}
