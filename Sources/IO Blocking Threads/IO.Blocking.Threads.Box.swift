//
//  IO.Blocking.Threads.Box.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 24/12/2025.
//

extension IO.Blocking.Threads {
    /// Type-erased boxing for job results.
    ///
    /// ## Design
    /// Each box consists of two allocations:
    /// - A header struct containing a destroy function and payload pointer
    /// - A payload containing the actual `Result<T, E>`
    ///
    /// This enables:
    /// - Correct destruction without knowing `T` or `E` (for abandonment paths)
    /// - Type-safe unboxing when the caller knows `T` and `E`
    /// - No leaks in cancel-wait-but-drain paths
    ///
    /// ## Memory Layout
    /// The returned pointer points to the Header struct, which contains:
    /// - `destroyPayload`: function to destroy payload (captures type info)
    /// - `payload`: pointer to the `Result<T, E>` storage
    ///
    /// ## Performance
    /// - No class = no ARC on the container
    /// - No Unmanaged overhead
    /// - Proper move() semantics for deallocation
    /// - Type erasure via closure (one closure allocation per box)
    ///
    /// ## Ownership Rules
    /// **Invariant:** Exactly one party allocates, exactly one party frees.
    ///
    /// - **Allocation:** `make()` allocates both header and payload
    /// - **Deallocation:** Either `take()` or `destroy()` deallocates both
    ///
    /// **Never call both `take()` and `destroy()` on the same pointer.**
    enum Box {
        /// Header for type-erased box.
        ///
        /// Struct-based (not class) to avoid ARC on the container.
        /// The destroy function captures type information for proper deinitialization.
        ///
        /// No Sendable conformance: Header is internal and only accessed
        /// behind lock-protected regions. The Box pointer itself is the capability.
        private struct Header {
            /// Function to destroy the payload.
            /// Captures type information (T, E) for proper deinitialization.
            let destroyPayload: (UnsafeMutableRawPointer) -> Void

            /// Pointer to the payload (Result<T, E>).
            let payload: UnsafeMutableRawPointer
        }

        /// Allocate and initialize a boxed Result.
        ///
        /// Returns a pointer to the erased header. Use `take<T,E>` to unbox
        /// or `destroy` to free without unboxing.
        static func make<T: Sendable, E: Swift.Error & Sendable>(
            _ result: Result<T, E>
        ) -> UnsafeMutableRawPointer {
            // Allocate payload
            let payloadPtr = UnsafeMutablePointer<Result<T, E>>.allocate(capacity: 1)
            payloadPtr.initialize(to: result)

            // Allocate header (struct, not class - no ARC on container)
            let headerPtr = UnsafeMutablePointer<Header>.allocate(capacity: 1)
            headerPtr.initialize(
                to: Header(
                    destroyPayload: { payloadRaw in
                        let payload = payloadRaw.assumingMemoryBound(to: Result<T, E>.self)
                        payload.deinitialize(count: 1)
                        payload.deallocate()
                    },
                    payload: UnsafeMutableRawPointer(payloadPtr)
                )
            )

            return UnsafeMutableRawPointer(headerPtr)
        }

        /// Destroy a boxed Result without reading it.
        ///
        /// Correctly deinitializes the payload (running destructors for T and E)
        /// and deallocates all memory. Safe to call without knowing T or E.
        ///
        /// - Important: Uses `move()` on Header before deallocate to properly
        ///   release the closure and balance the initialization from `make()`.
        static func destroy(_ ptr: UnsafeMutableRawPointer) {
            let headerPtr = ptr.assumingMemoryBound(to: Header.self)
            let header = headerPtr.move()  // deinitializes Header, releases closure
            header.destroyPayload(header.payload)
            headerPtr.deallocate()
        }

        /// Unbox and deallocate a Result.
        ///
        /// Moves the Result out of the box and deallocates all memory.
        /// Caller must provide the correct T and E types.
        ///
        /// - Important: Uses `move()` on Header before deallocate to properly
        ///   release the closure and balance the initialization from `make()`.
        static func take<T: Sendable, E: Swift.Error & Sendable>(
            _ ptr: UnsafeMutableRawPointer
        ) -> Result<T, E> {
            let headerPtr = ptr.assumingMemoryBound(to: Header.self)
            let header = headerPtr.move()  // deinitializes Header, releases closure
            let payloadPtr = header.payload.assumingMemoryBound(to: Result<T, E>.self)
            let result = payloadPtr.move()
            payloadPtr.deallocate()
            headerPtr.deallocate()
            // destroyPayload not called - we moved the payload out instead
            return result
        }
    }
}
