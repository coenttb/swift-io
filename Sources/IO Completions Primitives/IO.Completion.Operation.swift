//
//  IO.Completion.Operation.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 31/12/2025.
//

public import Buffer
public import IO_Primitives
public import Kernel

extension IO.Completion {
    /// A move-only operation to be submitted to a completion queue.
    ///
    /// Operations are created via static factory methods and submitted via
    /// `Queue.submit(_:)`. Each operation represents a single I/O request.
    ///
    /// ## Ownership
    ///
    /// Operations are move-only (`~Copyable`) to enforce:
    /// - Single submission (no duplicate operations)
    /// - Buffer ownership transfer (Pattern A)
    /// - Proper resource lifecycle
    ///
    /// ## Buffer Ownership (Pattern A)
    ///
    /// When an operation takes a buffer, it consumes ownership:
    /// ```swift
    /// var buffer = try Buffer.Aligned(byteCount: 4096, alignment: 4096)
    /// let op = IO.Completion.Operation.read(from: fd, into: buffer)
    /// // buffer is now consumed, owned by operation
    /// let result = try await queue.submit(op)
    /// // buffer is returned in result
    /// ```
    ///
    /// ## Thread Safety
    ///
    /// Operations are `Sendable` for transfer to the queue. The internal
    /// storage manages synchronization for state transitions.
    public struct Operation: ~Copyable, Sendable {
        /// Internal storage for the operation.
        @usableFromInline
        package let storage: Storage

        /// Creates an operation with the given storage.
        @usableFromInline
        package init(storage: Storage) {
            self.storage = storage
        }

        /// The unique ID of this operation (assigned at storage creation).
        @inlinable
        public var id: IO.Completion.ID { storage.id }

        /// The kind of operation.
        @inlinable
        public var kind: IO.Completion.Kind { storage.kind }

        /// The target descriptor.
        @inlinable
        public var descriptor: Kernel.Descriptor { storage.descriptor }
    }
}

// MARK: - Storage

extension IO.Completion.Operation {
    /// Internal storage for operation state and resources.
    ///
    /// Storage is a reference type to allow:
    /// - Pointer-based correlation with kernel completions
    /// - Shared access from poll thread and queue actor
    /// - Early completion detection (completion event stored before waiter armed)
    ///
    /// ## Thread Safety
    ///
    /// `@unchecked Sendable` because access is coordinated through the Queue actor.
    /// The Waiter provides the state machine for exactly-once completion semantics.
    public final class Storage: @unchecked Sendable {
        /// The operation ID.
        public let id: IO.Completion.ID

        /// The operation kind.
        public let kind: IO.Completion.Kind

        /// The target descriptor.
        public let descriptor: Kernel.Descriptor

        /// Owned buffer (for read/write operations).
        ///
        /// Access pattern:
        /// - Set at creation (for operations that use buffers)
        /// - Read/cleared at completion to return buffer to caller
        @usableFromInline
        package var buffer: Buffer.Aligned?

        /// File offset for positioned I/O (-1 for stream operations).
        public let offset: Int64

        /// Completion event, stored by drain() for early completion support.
        ///
        /// When a completion event arrives before the waiter is armed,
        /// the event is stored here so submit() can resume immediately.
        @usableFromInline
        package var completion: IO.Completion.Event?

        #if os(Linux)
            /// io_uring user_data for pointer recovery.
            @usableFromInline
            package var userData: UInt64

            /// Creates storage for Linux.
            @usableFromInline
            package init(
                id: IO.Completion.ID,
                kind: IO.Completion.Kind,
                descriptor: Kernel.Descriptor,
                buffer: consuming Buffer.Aligned?,
                offset: Int64
            ) {
                self.id = id
                self.kind = kind
                self.descriptor = descriptor
                self.buffer = buffer
                self.offset = offset
                self.completion = nil
                self.userData = 0
                // Now that all properties are initialized, set userData to self pointer
                self.userData = UInt64(UInt(bitPattern: Unmanaged.passUnretained(self).toOpaque()))
            }
        #else
            /// Creates storage.
            @usableFromInline
            package init(
                id: IO.Completion.ID,
                kind: IO.Completion.Kind,
                descriptor: Kernel.Descriptor,
                buffer: consuming Buffer.Aligned?,
                offset: Int64
            ) {
                self.id = id
                self.kind = kind
                self.descriptor = descriptor
                self.buffer = buffer
                self.offset = offset
                self.completion = nil
            }
        #endif
    }
}

// MARK: - Factory Methods

extension IO.Completion.Operation {
    /// Creates a read operation.
    ///
    /// Reads data from the descriptor into the buffer.
    ///
    /// - Parameters:
    ///   - descriptor: The file descriptor to read from.
    ///   - buffer: The buffer to read into (ownership transferred).
    ///   - offset: File offset for positioned read, or `nil` for stream read.
    ///   - id: The operation ID (typically assigned by the queue).
    /// - Returns: A read operation.
    @inlinable
    public static func read(
        from descriptor: Kernel.Descriptor,
        into buffer: consuming Buffer.Aligned,
        offset: Int64? = nil,
        id: IO.Completion.ID
    ) -> Self {
        let storage = Storage(
            id: id,
            kind: IO.Completion.Kind.read,
            descriptor: descriptor,
            buffer: buffer,
            offset: offset ?? -1
        )
        return Self(storage: storage)
    }

    /// Creates a write operation.
    ///
    /// Writes data from the buffer to the descriptor.
    ///
    /// - Parameters:
    ///   - descriptor: The file descriptor to write to.
    ///   - buffer: The buffer to write from (ownership transferred).
    ///   - offset: File offset for positioned write, or `nil` for stream write.
    ///   - id: The operation ID (typically assigned by the queue).
    /// - Returns: A write operation.
    @inlinable
    public static func write(
        to descriptor: Kernel.Descriptor,
        from buffer: consuming Buffer.Aligned,
        offset: Int64? = nil,
        id: IO.Completion.ID
    ) -> Self {
        let storage = Storage(
            id: id,
            kind: IO.Completion.Kind.write,
            descriptor: descriptor,
            buffer: buffer,
            offset: offset ?? -1
        )
        return Self(storage: storage)
    }

    /// Creates an accept operation.
    ///
    /// Accepts a new connection on a listening socket.
    ///
    /// - Parameters:
    ///   - descriptor: The listening socket descriptor.
    ///   - id: The operation ID.
    /// - Returns: An accept operation.
    @inlinable
    public static func accept(
        from descriptor: Kernel.Descriptor,
        id: IO.Completion.ID
    ) -> Self {
        let storage = Storage(
            id: id,
            kind: IO.Completion.Kind.accept,
            descriptor: descriptor,
            buffer: Optional<Buffer.Aligned>.none,
            offset: -1
        )
        return Self(storage: storage)
    }

    /// Creates a connect operation.
    ///
    /// Connects a socket to a remote address.
    ///
    /// - Parameters:
    ///   - descriptor: The socket descriptor.
    ///   - id: The operation ID.
    /// - Returns: A connect operation.
    ///
    /// - Note: The address is provided separately when submitting to
    ///   accommodate platform-specific address handling.
    @inlinable
    public static func connect(
        descriptor: Kernel.Descriptor,
        id: IO.Completion.ID
    ) -> Self {
        let storage = Storage(
            id: id,
            kind: IO.Completion.Kind.connect,
            descriptor: descriptor,
            buffer: Optional<Buffer.Aligned>.none,
            offset: -1
        )
        return Self(storage: storage)
    }

    /// Creates a no-operation.
    ///
    /// Useful for wakeup and testing.
    ///
    /// - Parameter id: The operation ID.
    /// - Returns: A nop operation.
    @inlinable
    public static func nop(id: IO.Completion.ID) -> Self {
        let storage = Storage(
            id: id,
            kind: IO.Completion.Kind.nop,
            descriptor: Kernel.Descriptor.invalid,
            buffer: Optional<Buffer.Aligned>.none,
            offset: -1
        )
        return Self(storage: storage)
    }

    /// Creates a cancel operation.
    ///
    /// Requests cancellation of a pending operation.
    ///
    /// - Parameters:
    ///   - targetID: The ID of the operation to cancel.
    ///   - id: The operation ID for this cancel request.
    /// - Returns: A cancel operation.
    @inlinable
    public static func cancel(
        targetID: IO.Completion.ID,
        id: IO.Completion.ID
    ) -> Self {
        let storage = Storage(
            id: id,
            kind: IO.Completion.Kind.cancel,
            descriptor: Kernel.Descriptor.invalid,
            buffer: Optional<Buffer.Aligned>.none,
            offset: Int64(targetID._rawValue)  // Encode target ID in offset
        )
        return Self(storage: storage)
    }
}

// MARK: - Description

extension IO.Completion.Operation {
    /// A textual description of this operation.
    public var description: String {
        "Operation(id: \(id._rawValue), kind: \(kind), descriptor: \(descriptor))"
    }
}
