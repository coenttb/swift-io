//
//  IO.Blocking.Threads.Box.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 24/12/2025.
//

extension IO.Blocking.Threads {
    /// Centralized boxing/unboxing for job results.
    ///
    /// All result boxing goes through this enum to ensure:
    /// - Consistent allocation/deallocation
    /// - No leaks in abandon/cancellation paths
    /// - Clear ownership semantics
    enum Box {
        /// Allocate and initialize a boxed Result.
        static func make<T, E: Swift.Error>(_ result: Result<T, E>) -> UnsafeMutableRawPointer {
            let ptr = UnsafeMutablePointer<Result<T, E>>.allocate(capacity: 1)
            ptr.initialize(to: result)
            return UnsafeMutableRawPointer(ptr)
        }

        /// Unbox and deallocate a Result.
        static func take<T, E: Swift.Error>(_ ptr: UnsafeMutableRawPointer) -> Result<T, E> {
            let typed = ptr.assumingMemoryBound(to: Result<T, E>.self)
            let result = typed.move()
            typed.deallocate()
            return result
        }

        /// Free a boxed Result without reading it.
        ///
        /// Used when a waiter is abandoned due to cancellation.
        /// The Result's payload is destructed but not returned.
        static func free<T, E: Swift.Error>(
            _ ptr: UnsafeMutableRawPointer,
            as type: Result<T, E>.Type
        ) {
            let typed = ptr.assumingMemoryBound(to: Result<T, E>.self)
            typed.deinitialize(count: 1)
            typed.deallocate()
        }

        /// Create a boxed failure Result for infrastructure errors.
        static func makeFailure(_ failure: IO.Blocking.Failure) -> UnsafeMutableRawPointer {
            // We use Never as the success type since this is an infrastructure failure.
            // The caller must interpret this correctly.
            let result: Result<Never, IO.Blocking.Failure> = .failure(failure)
            let ptr = UnsafeMutablePointer<Result<Never, IO.Blocking.Failure>>.allocate(capacity: 1)
            ptr.initialize(to: result)
            return UnsafeMutableRawPointer(ptr)
        }
    }
}
