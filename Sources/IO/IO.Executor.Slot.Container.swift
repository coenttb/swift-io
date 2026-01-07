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
    internal struct Container<Resource: ~Copyable & Sendable>: ~Copyable {
        /// The raw pointer to allocated memory, or nil if deallocated.
        private var raw: UnsafeMutableRawPointer?
        private var isInitialized: Bool = false
        private var isConsumed: Bool = false

        private init(raw: UnsafeMutableRawPointer) {
            self.raw = raw
        }
    }
}

// MARK: - Properties

extension IO.Executor.Slot.Container where Resource: ~Copyable {
    /// The address of the allocated memory as an opaque capability token.
    ///
    /// This is Sendable and can be captured in @Sendable closures.
    /// Pass to static methods like `withResource(at:)` or `initializeMemory(at:with:)`.
    internal var address: IO.Executor.Slot.Address {
        guard let raw = raw else {
            preconditionFailure("Slot already deallocated")
        }
        return IO.Executor.Slot.Address(bits: UInt(bitPattern: raw))
    }
}

// MARK: - Allocation

extension IO.Executor.Slot.Container where Resource: ~Copyable {
    /// Allocates a slot with storage for one Resource.
    internal static func allocate() -> IO.Executor.Slot.Container<Resource> {
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: MemoryLayout<Resource>.stride,
            alignment: MemoryLayout<Resource>.alignment
        )
        return IO.Executor.Slot.Container<Resource>(raw: raw)
    }
}

// MARK: - Initialization

extension IO.Executor.Slot.Container where Resource: ~Copyable {
    /// Initializes the slot with a resource, consuming ownership.
    /// Use this when the resource is available on the actor side.
    internal mutating func initialize(with resource: consuming Resource) {
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
    internal mutating func markInitialized() {
        precondition(!isInitialized, "Slot already initialized")
        precondition(!isConsumed, "Slot already consumed")
        isInitialized = true
    }
}

// MARK: - Static Access

extension IO.Executor.Slot.Container where Resource: ~Copyable {
    /// Execute a closure with inout access to the resource.
    ///
    /// **Must only be called from within the lane closure.**
    ///
    /// - Parameters:
    ///   - address: The opaque address token from `slot.address`.
    ///   - body: Closure receiving inout access to the resource.
    internal static func withResource<T, E: Swift.Error>(
        at address: IO.Executor.Slot.Address,
        _ body: (inout Resource) throws(E) -> T
    ) throws(E) -> T {
        let typed = address._pointer.assumingMemoryBound(to: Resource.self)
        return try body(&typed.pointee)
    }

    /// Initialize memory at the address location.
    ///
    /// **Must only be called from within the lane closure.**
    ///
    /// - Parameters:
    ///   - address: The opaque address token from `slot.address`.
    ///   - resource: The resource to store, ownership transferred.
    internal static func initializeMemory(
        at address: IO.Executor.Slot.Address,
        with resource: consuming Resource
    ) {
        address._pointer.initializeMemory(as: Resource.self, to: resource)
    }
}

// MARK: - Consumption

extension IO.Executor.Slot.Container where Resource: ~Copyable {
    /// Takes the resource out of the slot, consuming it.
    ///
    /// **Must only be called after the lane await returns and markInitialized().**
    internal mutating func take() -> Resource {
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
    internal mutating func deallocateRawOnly() {
        guard let p = raw else { return }
        raw = nil
        p.deallocate()
    }
}
