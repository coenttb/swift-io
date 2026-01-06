//
//  File.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 06/01/2026.
//

extension IO.Blocking.Threads.Completion {
    /// Typed result for completion - no existential errors.
    typealias Result = Swift.Result<Kernel.Handoff.Box.Pointer, IO.Lifecycle.Error<IO.Blocking.Lane.Error>>
}
