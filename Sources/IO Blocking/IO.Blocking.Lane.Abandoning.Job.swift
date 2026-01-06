//
//  IO.Blocking.Lane.Abandoning.Job.swift
//  swift-io
//
//  A job with atomic state for single-resume guarantee.
//

import Synchronization

extension IO.Blocking.Lane.Abandoning {
    /// A job with atomic state for single-resume guarantee.
    final class Job: @unchecked Sendable {
        /// Sendable success type for crossing concurrency boundaries.
        ///
        /// `UnsafeMutableRawPointer` is not Sendable. This wrapper concentrates
        /// the `@unchecked Sendable` at the handoff boundary.
        typealias Success = Kernel.Handoff.Box.Pointer

        /// Sendable result type for continuation resume.
        typealias Result = Swift.Result<Success, IO.Lifecycle.Error<IO.Blocking.Lane.Error>>

        let operation: @Sendable () -> UnsafeMutableRawPointer
        let state: Atomic<State>
        private var continuation: CheckedContinuation<Result, Never>?
        private let lock = Kernel.Thread.Mutex()

        init(operation: @Sendable @escaping () -> UnsafeMutableRawPointer) {
            self.operation = operation
            self.state = Atomic(.pending)
        }
    }
}

// MARK: - Continuation

extension IO.Blocking.Lane.Abandoning.Job {
    func setContinuation(_ cont: CheckedContinuation<Result, Never>) {
        lock.lock()
        self.continuation = cont
        lock.unlock()
    }
}

// MARK: - State Transitions

extension IO.Blocking.Lane.Abandoning.Job {
    /// Attempt to start running. Returns true if successful.
    func tryStart() -> Bool {
        let (exchanged, _) = state.compareExchange(
            expected: .pending,
            desired: .running,
            ordering: .acquiringAndReleasing
        )
        return exchanged
    }

    /// Attempt to complete successfully. Returns true if successful.
    ///
    /// Wraps the raw pointer in a Sendable container before resuming.
    func tryComplete(_ rawResult: UnsafeMutableRawPointer) -> Bool {
        let (exchanged, _) = state.compareExchange(
            expected: .running,
            desired: .completed,
            ordering: .acquiringAndReleasing
        )
        if exchanged {
            // Wrap at boundary: convert raw pointer to Sendable wrapper
            let boxedPtr = Success(rawResult)
            lock.lock()
            let cont = continuation
            continuation = nil
            lock.unlock()
            cont?.resume(returning: .success(boxedPtr))
        }
        return exchanged
    }

    /// Attempt to mark as timed out. Returns true if successful.
    func tryTimeout() -> Bool {
        let (exchanged, _) = state.compareExchange(
            expected: .running,
            desired: .timedOut,
            ordering: .acquiringAndReleasing
        )
        if exchanged {
            lock.lock()
            let cont = continuation
            continuation = nil
            lock.unlock()
            cont?.resume(returning: .failure(.timeout))
        }
        return exchanged
    }

    /// Attempt to cancel. Returns true if successful.
    func tryCancel() -> Bool {
        // Can cancel from pending or running
        var (exchanged, original) = state.compareExchange(
            expected: .pending,
            desired: .cancelled,
            ordering: .acquiringAndReleasing
        )
        if !exchanged && original == .running {
            (exchanged, _) = state.compareExchange(
                expected: .running,
                desired: .cancelled,
                ordering: .acquiringAndReleasing
            )
        }
        if exchanged {
            lock.lock()
            let cont = continuation
            continuation = nil
            lock.unlock()
            cont?.resume(returning: .failure(.cancellation))
        }
        return exchanged
    }

    /// Attempt to fail with error. Returns true if successful.
    func tryFail(_ error: IO.Lifecycle.Error<IO.Blocking.Lane.Error>) -> Bool {
        // Can fail from pending only
        let (exchanged, _) = state.compareExchange(
            expected: .pending,
            desired: .failed,
            ordering: .acquiringAndReleasing
        )
        if exchanged {
            lock.lock()
            let cont = continuation
            continuation = nil
            lock.unlock()
            cont?.resume(returning: .failure(error))
        }
        return exchanged
    }
}
