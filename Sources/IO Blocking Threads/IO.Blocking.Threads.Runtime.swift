//
//  IO.Blocking.Threads.Runtime.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 24/12/2025.
//

public import Dimension

extension IO.Blocking.Threads {
    /// Mutable runtime state for the Threads lane.
    ///
    /// ## Safety Invariant (for @unchecked Sendable)
    /// - `state` is thread-safe via its internal lock
    /// - `threads` is only mutated in `start()` before any concurrent access
    /// - `isStarted` and `threads` mutations are synchronized via state.lock
    ///
    /// ## Thread Handle Storage
    /// Uses `Kernel.Thread.Handle.Reference` wrappers to store ~Copyable
    /// `Kernel.Thread.Handle` values in arrays. The reference wrapper enforces
    /// exactly-once join semantics while allowing Copyable array storage.
    final class Runtime: @unchecked Sendable {
        let state: State
        private(set) var threads: [Kernel.Thread.Handle.Reference] = []
        private(set) var deadlineManagerThread: Kernel.Thread.Handle.Reference?
        private(set) var isStarted: Bool = false
        let options: Options

        init(options: Options) {
            self.options = options
            self.state = State(
                queueLimit: options.queueLimit,
                acceptanceWaitersLimit: options.acceptanceWaitersLimit
            )
        }
        
        // MARK: - Start Accessor
        
        /// Accessor for start operations.
        struct Start {
            let runtime: Runtime
            
            /// Start threads if not already started.
            func ifNeeded() {
                runtime.state.lock.lock()
                defer { runtime.state.lock.unlock() }
                
                guard !runtime.isStarted else { return }
                runtime.isStarted = true
                
                // Start worker threads
                // Thread creation failure is catastrophic - we use Kernel.Thread.trap
                // since the lane cannot function without its worker threads.
                for i in 0..<Int(runtime.options.workers) {
                    let worker = Worker(id: i, state: runtime.state)
                    let handle = Kernel.Thread.trap {
                        worker.run()
                    }
                    runtime.threads.append(Kernel.Thread.Handle.Reference(handle))
                }
                
                // Start deadline manager thread
                let deadlineManager = Deadline.Manager(state: runtime.state)
                let handle = Kernel.Thread.trap {
                    deadlineManager.run()
                }
                runtime.deadlineManagerThread = Kernel.Thread.Handle.Reference(handle)
            }
            
            /// Start threads if not already started.
            func callAsFunction() {
                ifNeeded()
            }
        }
        
        /// Accessor for start operations.
        var start: Start { Start(runtime: self) }
        
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
