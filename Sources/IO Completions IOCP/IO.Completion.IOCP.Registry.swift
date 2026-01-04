//
//  IO.Completion.IOCP.Registry.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 31/12/2025.
//

#if os(Windows)

    public import Kernel
    public import IO_Completions_Driver

    extension IO.Completion.IOCP {
        /// Distinguishes file handles from sockets for proper result querying.
        ///
        /// IOCP completions for files use `GetOverlappedResult` while sockets
        /// use `WSAGetOverlappedResult`. This enum tracks the resource type
        /// so poll can query errors correctly.
        ///
        /// ## Thread Confinement
        ///
        /// This type is only used within the poll-thread-confined `Registry`.
        /// Do not share across threads.
        public enum Resource: Equatable {
            case file(HANDLE)
            case socket(SOCKET)

            /// Returns the underlying Windows HANDLE.
            @inlinable
            public var handle: HANDLE {
                switch self {
                case .file(let h):
                    return h
                case .socket(let s):
                    // SOCKET is an alias for UINT_PTR on Windows
                    return HANDLE(bitPattern: Int(s))
                }
            }
        }
    }

    extension IO.Completion.IOCP {
        /// Poll-thread-confined registry for pending IOCP operations.
        ///
        /// The registry tracks pending operations to enable:
        /// - `CancelIoEx` by operation ID (requires OVERLAPPED pointer)
        /// - Exactly-once header deallocation on completion
        /// - Per-operation error querying via `GetOverlappedResult`
        ///
        /// ## Thread Confinement
        ///
        /// **This type is NOT Sendable.** All access must occur on the poll thread.
        /// The poll thread is the sole owner; no synchronization is needed.
        ///
        /// ## Ownership Rules
        ///
        /// - **Insert**: After header allocation, before issuing the syscall.
        /// - **Remove**: On completion only. Returns entry for deallocation.
        /// - **Peek**: For cancellation lookups. Does NOT remove (completion still arrives).
        /// - **Deallocation**: Header is freed exactly once, only when `remove()` succeeds.
        ///
        /// ## Lifecycle
        ///
        /// ```
        /// submit():
        ///   1. Allocate Header on heap
        ///   2. Insert into registry (precondition: ID unique)
        ///   3. Issue syscall (ReadFile, WriteFile, etc.)
        ///   4. On sync failure: remove and deallocate
        ///
        /// poll():
        ///   1. Get completion from IOCP
        ///   2. Recover header via container-of
        ///   3. Remove from registry (exactly-once)
        ///   4. Deallocate header only if remove succeeded
        ///
        /// cancel():
        ///   1. Peek registry (do NOT remove)
        ///   2. Call CancelIoEx with overlapped pointer
        ///   3. Completion (success or cancelled) arrives later via poll
        /// ```
        public struct Registry {
            /// Entry for a pending operation.
            public struct Entry {
                /// The operation ID.
                public let id: IO.Completion.ID

                /// The operation kind.
                public let kind: IO.Completion.Kind

                /// The underlying resource (file or socket).
                public let resource: Resource

                /// Heap-allocated header containing OVERLAPPED.
                public let header: UnsafeMutablePointer<Header>

                /// Pointer to the OVERLAPPED structure for Win32 APIs.
                @inlinable
                public var overlapped: UnsafeMutablePointer<OVERLAPPED> {
                    withUnsafeMutablePointer(to: &header.pointee.overlapped) { $0 }
                }
            }

            /// Pending operations by ID.
            private var entries: [IO.Completion.ID: Entry] = [:]

            /// Creates an empty registry.
            @inlinable
            public init() {}

            /// Inserts an entry into the registry.
            ///
            /// Call after allocating the header, before issuing the syscall.
            ///
            /// - Precondition: `id` must not already exist in the registry.
            ///   A duplicate ID indicates an internal invariant violation.
            ///
            /// - Parameters:
            ///   - id: The operation ID.
            ///   - kind: The operation kind.
            ///   - resource: The underlying file or socket.
            ///   - header: Heap-allocated header (ownership transferred to registry).
            @inlinable
            public mutating func insert(
                id: IO.Completion.ID,
                kind: IO.Completion.Kind,
                resource: Resource,
                header: UnsafeMutablePointer<Header>
            ) {
                precondition(
                    entries[id] == nil,
                    "Duplicate operation ID \(id._rawValue) inserted into IOCP registry"
                )
                entries[id] = Entry(id: id, kind: kind, resource: resource, header: header)
            }

            /// Peeks an entry without removing it.
            ///
            /// Use for cancellation lookups. The entry remains in the registry
            /// because the completion will still arrive (even if cancelled).
            ///
            /// - Parameter id: The operation ID.
            /// - Returns: The entry if found, `nil` otherwise.
            @inlinable
            public func peek(id: IO.Completion.ID) -> Entry? {
                entries[id]
            }

            /// Removes and returns an entry.
            ///
            /// Call from poll() after receiving a completion. The caller is
            /// responsible for deallocating the header **only if this returns non-nil**.
            ///
            /// - Parameter id: The operation ID.
            /// - Returns: The removed entry, or `nil` if not found.
            @inlinable
            public mutating func remove(id: IO.Completion.ID) -> Entry? {
                entries.removeValue(forKey: id)
            }

            /// Removes and returns all entries.
            ///
            /// Use for shutdown cleanup. The caller must deallocate all headers.
            ///
            /// - Returns: Array of all removed entries.
            @inlinable
            public mutating func removeAll() -> [Entry] {
                defer { entries.removeAll(keepingCapacity: false) }
                return Array(entries.values)
            }

            /// The number of pending operations.
            @inlinable
            public var count: Int {
                entries.count
            }
        }
    }

#endif  // os(Windows)
