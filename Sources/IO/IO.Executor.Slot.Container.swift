//
//  IO.Executor.Slot.Container.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 24/12/2025.
//

extension IO.Executor.Slot {
    /// A raw memory slot for temporarily holding a ~Copyable resource
    /// during lane execution.
    ///
    /// This enables passing resources through @Sendable closures without
    /// claiming the resource itself is Sendable.
    ///
    /// Generic over `Resource` which must be `~Copyable & Sendable`.
    public struct Container<Resource: ~Copyable & Sendable>: ~Copyable {
        /// The raw pointer to allocated memory, or nil if deallocated.
        private var raw: UnsafeMutableRawPointer?
        private var isInitialized: Bool = false
        private var isConsumed: Bool = false

        /// The address of the allocated memory as a typed capability.
        ///
        /// This is Sendable and can be captured in @Sendable closures.
        /// Use `address.pointer` inside the closure to reconstruct.
        public var address: Address {
            guard let raw = raw else {
                preconditionFailure("Slot already deallocated")
            }
            return Address(UInt(bitPattern: raw))
        }

        /// Allocates a slot with storage for one Resource.
        public static func allocate() -> Container {
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
        /// Use this when the resource is available on the actor side.
        public mutating func initialize(with resource: consuming Resource) {
            guard let raw = raw else {
                preconditionFailure("Slot already deallocated")
            }
            precondition(!isInitialized, "Slot already initialized")
            precondition(!isConsumed, "Slot already consumed")
            isInitialized = true
            raw.initializeMemory(as: Resource.self, to: resource)
        }

        /// Marks the slot as initialized after memory was written via static method.
        /// Call this after `lane.run` returns successfully.
        public mutating func markInitialized() {
            precondition(!isInitialized, "Slot already initialized")
            precondition(!isConsumed, "Slot already consumed")
            isInitialized = true
        }

        /// Execute a closure with inout access to the resource.
        ///
        /// **Must only be called from within the lane closure.**
        /// The `raw` pointer must be reconstructed from address inside the closure.
        public static func withResource<T, E: Swift.Error>(
            at raw: UnsafeMutableRawPointer,
            _ body: (inout Resource) throws(E) -> T
        ) throws(E) -> T {
            let typed = raw.assumingMemoryBound(to: Resource.self)
            return try body(&typed.pointee)
        }

        /// Initialize memory at the raw pointer location.
        ///
        /// **Must only be called from within the lane closure.**
        /// The `raw` pointer must be reconstructed from address inside the closure.
        public static func initializeMemory(
            at raw: UnsafeMutableRawPointer,
            with resource: consuming Resource
        ) {
            raw.initializeMemory(as: Resource.self, to: resource)
        }

        /// Takes the resource out of the slot, consuming it.
        ///
        /// **Must only be called after the lane await returns and markInitialized().**
        public mutating func take() -> Resource {
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
        /// This does NOT deinitialize any resource. Use via `defer` to ensure
        /// raw memory is always freed. Safe to call whether or not the slot
        /// was ever initialized or consumed.
        public mutating func deallocateRawOnly() {
            guard let p = raw else { return }
            raw = nil
            p.deallocate()
        }
    }
}
