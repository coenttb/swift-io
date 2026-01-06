//
//  IO.Blocking.Threads.Completion.Context.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 29/12/2025.
//

extension IO.Blocking.Threads.Completion {
    /// Typed result for completion - no existential errors.
    typealias Result = Swift.Result<Kernel.Handoff.Box.Pointer, IO.Lifecycle.Error<IO.Blocking.Lane.Error>>

    /// Context for exactly-once completion resumption.
    ///
    /// This is a typealias to `Kernel.Continuation.Context`, providing:
    /// - Atomic exactly-once resumption between completion, cancellation, and failure paths
    /// - Typed errors via `Result` (no `any Error` propagation)
    /// - Memory-safe state transitions with full fencing
    ///
    /// ## State Machine
    /// ```
    /// ┌─────────┐
    /// │ pending │ ──complete()──> [completed] ──resume(returning: .success(box))
    /// │   (0)   │ ──cancel()────> [cancelled] ──resume(returning: .failure(error))
    /// │         │ ──fail()──────> [failed]    ──resume(returning: .failure(error))
    /// └─────────┘
    /// ```
    ///
    /// ## Usage
    /// - `context.complete(box)` - Worker completed successfully
    /// - `context.cancel(.cancellation)` - Swift task was cancelled
    /// - `context.fail(.shutdownInProgress)` - Infrastructure failure
    typealias Context = Kernel.Continuation.Context<Kernel.Handoff.Box.Pointer, IO.Lifecycle.Error<IO.Blocking.Lane.Error>>
}
