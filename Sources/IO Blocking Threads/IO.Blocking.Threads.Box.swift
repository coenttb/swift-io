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
    /// Each box consists of:
    /// - A header containing a type-erased destroy function pointer
    /// - A payload containing the actual `Result<T, E>`
    ///
    /// This enables:
    /// - Correct destruction without knowing `T` or `E` (for abandonment paths)
    /// - Type-safe unboxing when the caller knows `T` and `E`
    /// - No leaks in cancel-wait-but-drain paths
    ///
    /// ## Memory Layout
    /// The returned pointer points to the Header, which contains:
    /// - `destroy`: function pointer to destroy payload and header
    /// - `payload`: pointer to the `Result<T, E>` storage
    enum Box {
        /// Header for type-erased box.
        ///
        /// This class holds the destroy closure and payload pointer.
        /// Using a class allows the destroy closure to capture the generic types.
        private final class Header: @unchecked Sendable {
            /// Function to destroy the payload and deallocate all memory.
            let destroy: @Sendable (UnsafeMutableRawPointer) -> Void

            /// Pointer to the payload (Result<T, E>).
            let payload: UnsafeMutableRawPointer

            init(
                destroy: @escaping @Sendable (UnsafeMutableRawPointer) -> Void,
                payload: UnsafeMutableRawPointer
            ) {
                self.destroy = destroy
                self.payload = payload
            }
        }

        /// Allocate and initialize a boxed Result.
        ///
        /// Returns a pointer to the erased header. Use `take<T,E>` to unbox
        /// or `destroy` to free without unboxing.
        static func make<T, E: Swift.Error>(_ result: Result<T, E>) -> UnsafeMutableRawPointer {
            // Allocate payload
            let payloadPtr = UnsafeMutablePointer<Result<T, E>>.allocate(capacity: 1)
            payloadPtr.initialize(to: result)

            // Create header with type-erased destroy closure
            let header = Header(
                destroy: { payloadRaw in
                    let payload = payloadRaw.assumingMemoryBound(to: Result<T, E>.self)
                    payload.deinitialize(count: 1)
                    payload.deallocate()
                },
                payload: UnsafeMutableRawPointer(payloadPtr)
            )

            // Return unmanaged pointer (transfers ownership)
            return UnsafeMutableRawPointer(Unmanaged.passRetained(header).toOpaque())
        }

        /// Destroy a boxed Result without reading it.
        ///
        /// Correctly deinitializes the payload (running destructors for T and E)
        /// and deallocates all memory. Safe to call without knowing T or E.
        static func destroy(_ ptr: UnsafeMutableRawPointer) {
            let header = Unmanaged<Header>.fromOpaque(ptr).takeRetainedValue()
            header.destroy(header.payload)
        }

        /// Unbox and deallocate a Result.
        ///
        /// Moves the Result out of the box and deallocates all memory.
        /// Caller must provide the correct T and E types.
        static func take<T, E: Swift.Error>(_ ptr: UnsafeMutableRawPointer) -> Result<T, E> {
            let header = Unmanaged<Header>.fromOpaque(ptr).takeRetainedValue()
            let payload = header.payload.assumingMemoryBound(to: Result<T, E>.self)

            // Move out the result
            let result = payload.move()

            // Deallocate payload (already deinitialized by move)
            payload.deallocate()

            // Header is automatically deallocated when it goes out of scope (takeRetainedValue)
            return result
        }
    }
}
