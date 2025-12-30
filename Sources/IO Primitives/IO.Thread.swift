//
//  IO.Thread.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 28/12/2025.
//

extension IO {
    /// Namespace for thread-related primitives.
    ///
    /// ## Spawning Threads
    /// Use `IO.Thread.spawn` to create OS threads:
    /// ```swift
    /// let handle = try IO.Thread.spawn { print("Hello from thread") }
    /// handle.join()
    /// ```
    ///
    /// Thread creation can fail (resource limits, OS policy), so the API uses
    /// typed throws with `IO.Thread.Spawn.Error`.
    public enum Thread {}
}
