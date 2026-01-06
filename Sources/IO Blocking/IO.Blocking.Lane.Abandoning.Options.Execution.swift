//
//  IO.Blocking.Lane.Abandoning.Options.Execution.swift
//  swift-io
//
//  Execution configuration for the abandoning lane.
//

extension IO.Blocking.Lane.Abandoning.Options {
    /// Execution-related configuration.
    public struct Execution: Sendable {
        /// Maximum time an operation may execute before being abandoned.
        ///
        /// If an operation exceeds this timeout:
        /// - The caller receives a timeout error
        /// - The operation continues on the abandoned thread
        /// - A replacement worker is spawned (if under workers.max)
        ///
        /// Choose a value that catches genuinely hung operations without
        /// triggering on legitimately slow operations.
        public var timeout: Duration

        public init(timeout: Duration = .seconds(30)) {
            self.timeout = timeout
        }
    }
}
