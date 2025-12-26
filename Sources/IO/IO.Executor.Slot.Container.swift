//
//  IO.Executor.Slot.Container.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 24/12/2025.
//

extension IO.Executor.Slot {
    /// A raw memory slot for temporarily holding a ~Copyable resource during lane execution.
    ///
    /// ## Unsafe Boundary Contract
    ///
    /// This type forms part of the unsafe memory boundary for resource transport.
    /// All unsafe pointer operations for slot-based resource management are confined here.
    ///
    /// **Provenance**: Pointers originate from `allocate()` using `MemoryLayout<Resource>`.
    /// The same `Resource` type must be used for all operations on a given slot.
    ///
    /// **Alignment**: Memory is allocated with `MemoryLayout<Resource>.alignment`.
    /// All access assumes proper alignment for `Resource`.
    ///
    /// **Lifetime**: From `allocate()` to `deallocateRawOnly()`.
    /// Between these, the slot may be:
    /// - Uninitialized (after allocate, before initialize/initializeMemory)
    /// - Initialized (after initialize, before take)
    /// - Consumed (after take, before deallocate)
    ///
    /// **Permitted Operations**:
    /// - `allocate()`: Allocate raw storage
    /// - `initialize(with:)` / `initializeMemory(at:with:)`: Initialize storage
    /// - `withResource(at:_:)`: Borrow access (does not consume)
    /// - `take()` / `take(at:)` / `consume(at:_:)`: Move out (consumes)
    /// - `deallocateRawOnly()`: Deallocate storage (must be consumed or never initialized)
    ///
    /// **State Machine**:
    /// ```
    /// allocate() → [uninitialized]
    ///            → initialize() → [initialized]
    ///                           → take() → [consumed]
    ///                                    → deallocateRawOnly() → [freed]
    /// ```
    ///
    /// Enables passing resources through @Sendable closures without
    /// claiming the resource itself is Sendable. The address is Sendable,
    /// but the resource stays in one place and is accessed via pointer.
    struct Container<Resource: ~Copyable>: ~Copyable {
        /// The raw pointer to allocated memory, or nil if deallocated.
        private var raw: UnsafeMutableRawPointer?
        private var isInitialized: Bool = false
        private var isConsumed: Bool = false

        /// The address of the allocated memory as a typed capability.
        ///
        /// Sendable - can be captured in @Sendable closures.
        /// Use `address.pointer` inside the closure to reconstruct.
        var address: Address {
            guard let raw = raw else {
                preconditionFailure("Slot already deallocated")
            }
            return Address(UInt(bitPattern: raw))
        }

        /// Allocates a slot with storage for one Resource.
        static func allocate() -> Container {
            let raw = UnsafeMutableRawPointer.allocate(
                byteCount: MemoryLayout<Resource>.stride,
                alignment: MemoryLayout<Resource>.alignment
            )
            return Container(raw: raw)
        }

        private init(raw: UnsafeMutableRawPointer) {
            self.raw = raw
        }

        /// Initializes the slot with a resource, consuming ownership.
        ///
        /// Use this when the resource is available on the actor side.
        mutating func initialize(with resource: consuming Resource) {
            guard let raw = raw else {
                preconditionFailure("Slot already deallocated")
            }
            precondition(!isInitialized, "Slot already initialized")
            precondition(!isConsumed, "Slot already consumed")
            isInitialized = true
            raw.initializeMemory(as: Resource.self, to: resource)
        }

        /// Marks the slot as initialized after memory was written via static method.
        ///
        /// Call this after `lane.run` returns successfully.
        mutating func markInitialized() {
            precondition(!isInitialized, "Slot already initialized")
            precondition(!isConsumed, "Slot already consumed")
            isInitialized = true
        }

        /// Executes a closure with inout access to the resource.
        ///
        /// Must only be called from within the lane closure.
        /// The `raw` pointer must be reconstructed from address inside the closure.
        static func withResource<T, E: Swift.Error>(
            at raw: UnsafeMutableRawPointer,
            _ body: (inout Resource) throws(E) -> T
        ) throws(E) -> T {
            let typed = raw.assumingMemoryBound(to: Resource.self)
            return try body(&typed.pointee)
        }

        /// Initializes memory at the raw pointer location.
        ///
        /// Must only be called from within the lane closure.
        /// The `raw` pointer must be reconstructed from address inside the closure.
        static func initializeMemory(
            at raw: UnsafeMutableRawPointer,
            with resource: consuming Resource
        ) {
            raw.initializeMemory(as: Resource.self, to: resource)
        }

        /// Takes the resource out of the slot at the given raw pointer, consuming it.
        ///
        /// This is the static variant for use inside lane closures or teardown
        /// where only the address is available.
        ///
        /// - Parameter raw: The raw pointer (reconstructed from `address.pointer`).
        /// - Returns: The resource, with ownership transferred to caller.
        static func take(at raw: UnsafeMutableRawPointer) -> Resource {
            let typed = raw.assumingMemoryBound(to: Resource.self)
            return typed.move()
        }

        /// Consumes the resource at the given raw pointer, passing it to a closure.
        ///
        /// This is the canonical API for teardown closures. It ensures the resource
        /// is moved out of the slot exactly once and consumed by the closure.
        ///
        /// ## Example: File Handle Teardown
        /// ```swift
        /// teardown: { address in
        ///     _ = try? await lane.run(deadline: nil) {
        ///         IO.Executor.Slot.Container<File.Handle>.consume(at: address.pointer) {
        ///             try? $0.close()
        ///         }
        ///     }
        /// }
        /// ```
        ///
        /// - Parameters:
        ///   - raw: The raw pointer (reconstructed from `address.pointer`).
        ///   - body: Closure that consumes the resource.
        /// - Returns: The result of the closure.
        static func consume<R>(
            at raw: UnsafeMutableRawPointer,
            _ body: (consuming Resource) throws -> R
        ) rethrows -> R {
            let resource = take(at: raw)
            return try body(resource)
        }

        /// Takes the resource out of the slot, consuming it.
        ///
        /// Must only be called after the lane await returns and `markInitialized()`.
        mutating func take() -> Resource {
            guard let raw = raw else {
                preconditionFailure("Slot already deallocated")
            }
            precondition(isInitialized, "Slot not initialized")
            precondition(!isConsumed, "Slot already consumed")
            isConsumed = true

            let typed = raw.assumingMemoryBound(to: Resource.self)
            return typed.move()
        }

        /// Deallocates the slot's raw storage only. Idempotent.
        ///
        /// Does NOT deinitialize any resource. Use via defer to ensure
        /// raw memory is always freed. Safe to call whether or not the slot
        /// was ever initialized or consumed.
        mutating func deallocateRawOnly() {
            guard let p = raw else { return }
            raw = nil
            p.deallocate()
        }
    }
}
