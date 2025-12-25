//
//  IO.Blocking.Box.swift
//  swift-io
//

extension IO.Blocking.Box {
    /// Sendable capability wrapper for boxed pointers.
    ///
    /// This is the only `@unchecked Sendable` in the lane internals.
    /// It represents a capability to consume or destroy a box, and
    /// concentrates the unsafe sendability at the FFI boundary.
    package struct Pointer: @unchecked Sendable {
        package let raw: UnsafeMutableRawPointer
        package init(_ raw: UnsafeMutableRawPointer) { self.raw = raw }
    }
}

extension IO.Blocking {
    /// Type-erased boxing for lane results.
    ///
    /// ## Unsafe Boundary Contract
    ///
    /// This type forms part of the unsafe memory boundary for lane execution.
    /// All unsafe pointer operations are confined to this file.
    ///
    /// **Provenance**: Pointers returned by `make`/`makeValue` originate from
    /// `UnsafeMutablePointer.allocate` and must be consumed exactly once.
    ///
    /// **Alignment**: Header and payload are separately allocated with natural
    /// alignment for their respective types.
    ///
    /// **Lifetime**: From `make*()` to either `take*()` or `destroy()`.
    /// The caller must ensure exactly one consumption path is taken.
    ///
    /// **Permitted Operations**:
    /// - `make(Result<T, E>)` / `makeValue(T)`: Allocate and initialize
    /// - `take<T, E>(ptr)` / `takeValue<T>(ptr)`: Move out and deallocate
    /// - `destroy(ptr)`: Deinitialize and deallocate without reading
    ///
    /// ## Design
    /// Each box consists of two allocations:
    /// - A header struct containing a destroy function and payload pointer
    /// - A payload containing the actual `Result<T, E>` or raw value `T`
    ///
    /// This enables:
    /// - Correct destruction without knowing `T` or `E` (for abandonment paths)
    /// - Type-safe unboxing when the caller knows `T` and `E`
    /// - No leaks in cancel-wait-but-drain paths
    ///
    /// ## Memory Layout
    /// The returned pointer points to the Header struct, which contains:
    /// - `destroyPayload`: function to destroy payload (captures type info)
    /// - `payload`: pointer to the `Result<T, E>` or `T` storage
    ///
    /// ## Ownership Rules
    /// **Invariant:** Exactly one party allocates, exactly one party frees.
    ///
    /// - **Allocation:** `make()` or `makeValue()` allocates both header and payload
    /// - **Deallocation:** Either `take()`/`takeValue()` or `destroy()` deallocates both
    ///
    /// **Never call both `take*()` and `destroy()` on the same pointer.**
    ///
    // Why Closure (Future: Replace with Thin Function Pointer)
    // The closure captures T and E type information needed for proper
    // deinitialization. Ideally we'd use @convention(thin) function pointers
    // with unsafeBitCast to erase the generic signature, eliminating the
    // closure allocation. However:
    // - Swift 6.2.3 crashes when unsafeBitCasting generic thin function pointers
    // - Static witness-per-specialization patterns are blocked by Swift restrictions
    // Revisit when the compiler bug is fixed.
    package enum Box {
        // Header for type-erased box.
        // Struct-based (not class) to avoid ARC on the container.
        // The destroy function captures type information for proper deinitialization.
        private struct Header {
            // Function to destroy the payload.
            // Captures type information (T, E) for proper deinitialization.
            let destroyPayload: (UnsafeMutableRawPointer) -> Void

            // Pointer to the payload (Result<T, E> or T).
            let payload: UnsafeMutableRawPointer
        }

        // MARK: - Result Boxing

        /// Allocate and initialize a boxed Result.
        ///
        /// Returns a pointer to the erased header. Use `take<T,E>` to unbox
        /// or `destroy` to free without unboxing.
        package static func make<T: Sendable, E: Swift.Error & Sendable>(
            _ result: Result<T, E>
        ) -> UnsafeMutableRawPointer {
            // Allocate payload
            let payloadPtr = UnsafeMutablePointer<Result<T, E>>.allocate(capacity: 1)
            payloadPtr.initialize(to: result)

            // Allocate header
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

        /// Unbox and deallocate a Result.
        ///
        /// Moves the Result out of the box and deallocates all memory.
        /// Caller must provide the correct T and E types.
        package static func take<T: Sendable, E: Swift.Error & Sendable>(
            _ ptr: UnsafeMutableRawPointer
        ) -> Result<T, E> {
            let headerPtr = ptr.assumingMemoryBound(to: Header.self)
            let header = headerPtr.move()  // releases closure
            let payloadPtr = header.payload.assumingMemoryBound(to: Result<T, E>.self)
            let result = payloadPtr.move()
            payloadPtr.deallocate()
            headerPtr.deallocate()
            // destroyPayload not called - we moved the payload out instead
            return result
        }

        // MARK: - Value Boxing (Non-Result)

        /// Allocate and initialize a boxed value.
        ///
        /// Returns a pointer to the erased header. Use `takeValue<T>` to unbox
        /// or `destroy` to free without unboxing.
        package static func makeValue<T: Sendable>(
            _ value: T
        ) -> UnsafeMutableRawPointer {
            // Allocate payload
            let payloadPtr = UnsafeMutablePointer<T>.allocate(capacity: 1)
            payloadPtr.initialize(to: value)

            // Allocate header
            let headerPtr = UnsafeMutablePointer<Header>.allocate(capacity: 1)
            headerPtr.initialize(
                to: Header(
                    destroyPayload: { payloadRaw in
                        let payload = payloadRaw.assumingMemoryBound(to: T.self)
                        payload.deinitialize(count: 1)
                        payload.deallocate()
                    },
                    payload: UnsafeMutableRawPointer(payloadPtr)
                )
            )

            return UnsafeMutableRawPointer(headerPtr)
        }

        /// Unbox and deallocate a value.
        ///
        /// Moves the value out of the box and deallocates all memory.
        /// Caller must provide the correct T type.
        package static func takeValue<T: Sendable>(
            _ ptr: UnsafeMutableRawPointer
        ) -> T {
            let headerPtr = ptr.assumingMemoryBound(to: Header.self)
            let header = headerPtr.move()  // releases closure
            let payloadPtr = header.payload.assumingMemoryBound(to: T.self)
            let result = payloadPtr.move()
            payloadPtr.deallocate()
            headerPtr.deallocate()
            return result
        }

        // MARK: - Type-Erased Destruction

        /// Destroy a boxed value without reading it.
        ///
        /// Correctly deinitializes the payload (running destructors for T and E)
        /// and deallocates all memory. Safe to call without knowing T or E.
        ///
        /// - Important: Uses `move()` on Header before deallocate to properly
        ///   release the closure and balance the initialization from `make()`.
        package static func destroy(_ ptr: UnsafeMutableRawPointer) {
            let headerPtr = ptr.assumingMemoryBound(to: Header.self)
            let header = headerPtr.move()  // releases closure
            header.destroyPayload(header.payload)
            headerPtr.deallocate()
        }
    }
}
