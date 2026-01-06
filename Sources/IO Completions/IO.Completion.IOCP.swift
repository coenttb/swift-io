//
//  IO.Completion.IOCP.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 31/12/2025.
//

#if os(Windows)

    public import Kernel
    

    extension IO.Completion {
        /// Windows IOCP (I/O Completion Ports) backend.
        ///
        /// IOCP is Windows' native completion-based I/O mechanism.
        /// It provides:
        /// - True async I/O at the kernel level
        /// - Efficient thread pooling
        /// - Batched completion retrieval
        ///
        /// ## Design
        ///
        /// Uses the container-of pattern: `OVERLAPPED` is placed as the
        /// first field in `Header`, allowing pointer recovery from the
        /// completion notification.
        ///
        /// ## Required: FILE_FLAG_OVERLAPPED
        ///
        /// All file handles used with this driver **must** be opened with
        /// `FILE_FLAG_OVERLAPPED`. This ensures:
        /// - Overlapped I/O operations post completions to the IOCP
        /// - Even synchronous completions are delivered via the completion port
        ///
        /// If a handle is opened without this flag, IOCP operations will fail
        /// or behave incorrectly.
        ///
        /// ## Thread Safety
        ///
        /// - `PostQueuedCompletionStatus`: Thread-safe (for wakeup)
        /// - `GetQueuedCompletionStatusEx`: Single-consumer (poll thread)
        /// - All state (registry, associations) is poll-thread-confined
        public enum IOCP {}
    }

    // MARK: - State

    extension IO.Completion.IOCP {
        /// Poll-thread-confined state for the IOCP driver.
        ///
        /// This class holds all mutable state needed by the driver.
        /// It is `@unchecked Sendable` because all access happens on the poll thread.
        ///
        /// ## Ownership
        ///
        /// - Created once per driver via `driver()`
        /// - Captured by driver closures
        /// - Mutated only on poll thread (no locks needed)
        final class State: @unchecked Sendable {
            /// Registry of pending operations.
            var registry: Registry = Registry()

            /// Set of already-associated file handles.
            /// Used to avoid re-associating handles with the IOCP.
            var associatedHandles: Set<UInt> = []

            init() {}
        }
    }

    // MARK: - Driver Factory

    extension IO.Completion.IOCP {
        /// Creates an IOCP driver instance.
        ///
        /// The driver uses a shared `State` object that is captured by
        /// all closures and mutated only on the poll thread.
        ///
        /// - Returns: A configured driver for Windows IOCP.
        public static func driver() -> IO.Completion.Driver {
            let state = State()

            return IO.Completion.Driver(
                capabilities: capabilities,
                create: create,
                submitStorage: { handle, storage in
                    try submitStorage(handle, storage, state)
                },
                flush: flush,
                poll: { handle, deadline, buffer in
                    try poll(handle, deadline, &buffer, state)
                },
                close: { handle in
                    close(handle, state)
                },
                createWakeupChannel: createWakeupChannel
            )
        }

        /// IOCP capabilities.
        public static let capabilities = IO.Completion.Driver.Capabilities(
            maxSubmissions: Int.max,  // No batching, immediate submission
            maxCompletions: 64,  // GetQueuedCompletionStatusEx batch size
            supportedKinds: .iocp,
            batchedSubmission: false,
            registeredBuffers: false,
            multishot: false
        )
    }

    // MARK: - Driver Implementation

    extension IO.Completion.IOCP {
        /// Creates an IOCP handle.
        static func create() throws(IO.Completion.Error) -> IO.Completion.Driver.Handle {
            // Verify Header layout at startup (debug only)
            Header.verifyLayout()

            do {
                let descriptor = try Kernel.IOCP.create()
                return IO.Completion.Driver.Handle(raw: descriptor.rawValue)
            } catch let error as Kernel.IOCP.Error {
                throw .kernel(error.asKernelError)
            }
        }

        /// Submits operation storage to IOCP.
        static func submitStorage(
            _ handle: borrowing IO.Completion.Driver.Handle,
            _ storage: IO.Completion.Operation.Storage,
            _ state: State
        ) throws(IO.Completion.Error) {
            // Get the file handle from the descriptor
            let fileHandle = storage.descriptor

            // Associate handle with IOCP if not already associated
            try associateIfNeeded(fileHandle: fileHandle, iocpHandle: handle.raw, state: state)

            // Dispatch based on operation kind
            switch storage.kind {
            case .read:
                try submitRead(handle, storage, state)
            case .write:
                try submitWrite(handle, storage, state)
            case .cancel:
                try submitCancel(handle, storage, state)
            case .nop, .wakeup:
                // These are handled via PostQueuedCompletionStatus, not actual I/O
                break
            case .accept, .connect, .send, .recv:
                // Socket operations are implemented in swift-sockets
                throw .capability(.unsupportedKind(storage.kind))
            default:
                throw .capability(.unsupportedKind(storage.kind))
            }
        }

        /// Flushes pending submissions (no-op for IOCP).
        static func flush(_ handle: borrowing IO.Completion.Driver.Handle) throws(IO.Completion.Error) -> Int {
            // IOCP has immediate submission, nothing to flush
            return 0
        }

        /// Polls for completion events.
        static func poll(
            _ handle: borrowing IO.Completion.Driver.Handle,
            _ deadline: IO.Completion.Deadline?,
            _ buffer: inout [IO.Completion.Event],
            _ state: State
        ) throws(IO.Completion.Error) -> Int {
            var entries = [OVERLAPPED_ENTRY](repeating: OVERLAPPED_ENTRY(), count: 64)
            var numRemoved: ULONG = 0

            let timeout: DWORD
            if let deadline {
                let remaining = deadline.rawValue.remainingNanoseconds
                if remaining <= 0 {
                    timeout = 0
                } else {
                    // Convert to milliseconds, saturate at INFINITE - 1
                    let ms = remaining / 1_000_000
                    timeout = ms > DWORD(INFINITE - 1) ? DWORD(INFINITE - 1) : DWORD(ms)
                }
            } else {
                timeout = INFINITE
            }

            let success = GetQueuedCompletionStatusEx(
                handle.raw,
                &entries,
                ULONG(entries.count),
                &numRemoved,
                timeout,
                false  // Don't alert
            )

            if !success {
                let error = GetLastError()
                if error == WAIT_TIMEOUT {
                    return 0
                }
                throw .kernel(.platform(code: Int32(error), message: "GetQueuedCompletionStatusEx failed"))
            }

            // Convert OVERLAPPED_ENTRY to Event
            for i in 0..<Int(numRemoved) {
                let entry = entries[i]

                // Wakeup sentinel: lpOverlapped == nil
                // Note: We only check lpOverlapped, not lpCompletionKey
                if entry.lpOverlapped == nil {
                    buffer.append(
                        IO.Completion.Event(
                            id: .zero,
                            kind: .wakeup,
                            outcome: .success(.completed)
                        )
                    )
                    continue
                }

                // Recover header via container-of pattern
                let headerPtr = Header.from(overlapped: entry.lpOverlapped!)
                let id = headerPtr.pointee.id
                let kind = headerPtr.pointee.kind

                // Remove from registry (exactly-once deallocation)
                guard let registryEntry = state.registry.remove(id: id) else {
                    // Completion for unknown ID - this is an internal invariant violation.
                    // Possible causes:
                    // - ID was never inserted (bug in submit path)
                    // - ID was already removed (double completion from kernel - very rare)
                    // - Registry corruption
                    //
                    // Do NOT free the header here - we don't have ownership.
                    // In debug: trap to surface the bug early.
                    // In release: skip to avoid UAF, leak is preferable.
                    assertionFailure("IOCP completion for unknown operation ID \(id.rawValue)")
                    continue
                }

                // Get bytes from OVERLAPPED_ENTRY
                let bytesTransferred = Int(entry.dwNumberOfBytesTransferred)

                // Get error status via GetOverlappedResult
                var transferredCheck: DWORD = 0
                let outcome: IO.Completion.Outcome

                let opSuccess = GetOverlappedResult(
                    registryEntry.resource.handle,
                    entry.lpOverlapped,
                    &transferredCheck,
                    false  // Don't wait
                )

                if opSuccess {
                    // Success - use bytes from the entry
                    switch kind {
                    case .read, .write, .send, .recv:
                        outcome = .success(.bytes(bytesTransferred))
                    case .accept:
                        // For accept, bytesTransferred may contain local/remote address info
                        // The actual accepted socket comes from a different mechanism (AcceptEx output)
                        outcome = .success(.completed)
                    case .connect:
                        outcome = .success(.connected)
                    default:
                        outcome = .success(.completed)
                    }
                } else {
                    let error = GetLastError()
                    if error == ERROR_OPERATION_ABORTED {
                        outcome = .cancellation
                    } else {
                        outcome = .failure(.platform(code: Int32(error), message: "IOCP operation failed"))
                    }
                }

                buffer.append(
                    IO.Completion.Event(
                        id: id,
                        kind: kind,
                        outcome: outcome,
                        userData: UInt64(UInt(bitPattern: entry.lpOverlapped))
                    )
                )

                // Deallocate header exactly once
                registryEntry.header.deinitialize(count: 1)
                registryEntry.header.deallocate()
            }

            return Int(numRemoved)
        }

        /// Closes the IOCP handle and cleans up state.
        static func close(_ handle: consuming IO.Completion.Driver.Handle, _ state: State) {
            // Clean up any remaining registry entries
            let remaining = state.registry.removeAll()
            for entry in remaining {
                entry.header.deinitialize(count: 1)
                entry.header.deallocate()
            }

            // Close the IOCP handle
            Kernel.IOCP.close(Kernel.Descriptor(rawValue: handle.raw))
        }

        /// Creates a wakeup channel for IOCP.
        static func createWakeupChannel(
            _ handle: borrowing IO.Completion.Driver.Handle
        ) throws(IO.Completion.Error) -> IO.Completion.Wakeup.Channel {
            // Capture the descriptor for the wakeup closure
            let port = Kernel.Descriptor(rawValue: handle.raw)

            return IO.Completion.Wakeup.Channel(
                wake: {
                    // Post a completion with no overlapped as wakeup sentinel
                    try? Kernel.IOCP.post(port)
                },
                close: nil  // No cleanup needed
            )
        }
    }

    // MARK: - Handle Association

    extension IO.Completion.IOCP {
        /// Associates a file handle with the IOCP if not already associated.
        ///
        /// IOCP requires each file handle to be associated with the completion port
        /// before any overlapped I/O can be performed. Association is permanent for
        /// the lifetime of the file handle.
        ///
        /// ## Completion Key
        ///
        /// The completion key is set to 0 and is **not used** for operation correlation.
        /// Instead, correlation is performed via the container-of pattern:
        ///
        /// ```
        /// OVERLAPPED* → Header* → Header.id → Registry lookup
        /// ```
        ///
        /// This keeps the design consistent with the plan's "single-funnel" invariant
        /// where all operation tracking flows through the registry.
        ///
        /// - Parameters:
        ///   - fileHandle: The file or socket handle to associate.
        ///   - iocpHandle: The IOCP handle.
        ///   - state: The driver state (for tracking associations).
        private static func associateIfNeeded(
            fileHandle: HANDLE,
            iocpHandle: HANDLE,
            state: State
        ) throws(IO.Completion.Error) {
            let key = UInt(bitPattern: fileHandle)

            // Check if already associated
            guard !state.associatedHandles.contains(key) else {
                return
            }

            // Associate with IOCP (completion key = 0, unused for correlation)
            do {
                try Kernel.IOCP.associate(
                    Kernel.Descriptor(rawValue: iocpHandle),
                    fileHandle: fileHandle,
                    completionKey: Kernel.IOCP.CompletionKey(rawValue: 0)
                )
            } catch let error as Kernel.IOCP.Error {
                throw .kernel(error.asKernelError)
            }

            // Track association
            state.associatedHandles.insert(key)
        }
    }

    // MARK: - Operation Submissions

    extension IO.Completion.IOCP {
        /// Allocates a header on the heap.
        ///
        /// The returned pointer must be deallocated via `deallocateHeader()` or
        /// by the registry removal path in `poll()`.
        @inline(__always)
        private static func allocateHeader(
            id: IO.Completion.ID,
            kind: IO.Completion.Kind
        ) -> UnsafeMutablePointer<Header> {
            let ptr = UnsafeMutablePointer<Header>.allocate(capacity: 1)
            ptr.initialize(to: Header(id: id, kind: kind))
            return ptr
        }

        /// Submits a read operation.
        private static func submitRead(
            _ handle: borrowing IO.Completion.Driver.Handle,
            _ storage: IO.Completion.Operation.Storage,
            _ state: State
        ) throws(IO.Completion.Error) {
            guard let buffer = storage.buffer else {
                throw .operation(.invalidSubmission)
            }

            let fileHandle = storage.descriptor

            // Allocate header
            let headerPtr = allocateHeader(id: storage.id, kind: .read)

            // Set up offset for positioned I/O
            if storage.offset >= 0 {
                headerPtr.pointee.overlapped.Offset = DWORD(truncatingIfNeeded: storage.offset)
                headerPtr.pointee.overlapped.OffsetHigh = DWORD(truncatingIfNeeded: storage.offset >> 32)
            }

            // Insert into registry BEFORE syscall (precondition: ID is unique)
            state.registry.insert(
                id: storage.id,
                kind: .read,
                resource: .file(fileHandle),
                header: headerPtr
            )

            // Issue syscall
            var bytesRead: DWORD = 0
            let success = ReadFile(
                fileHandle,
                buffer.baseAddress,
                DWORD(buffer.count),
                &bytesRead,
                &headerPtr.pointee.overlapped
            )

            if !success {
                let error = GetLastError()
                if error != ERROR_IO_PENDING {
                    // Synchronous failure: remove from registry and deallocate
                    _ = state.registry.remove(id: storage.id)
                    headerPtr.deinitialize(count: 1)
                    headerPtr.deallocate()
                    throw .kernel(.platform(code: Int32(error), message: "ReadFile failed"))
                }
                // ERROR_IO_PENDING = async in progress, completion arrives later
            }
            // Synchronous success also posts to IOCP for FILE_FLAG_OVERLAPPED handles
        }

        /// Submits a write operation.
        private static func submitWrite(
            _ handle: borrowing IO.Completion.Driver.Handle,
            _ storage: IO.Completion.Operation.Storage,
            _ state: State
        ) throws(IO.Completion.Error) {
            guard let buffer = storage.buffer else {
                throw .operation(.invalidSubmission)
            }

            let fileHandle = storage.descriptor

            // Allocate header
            let headerPtr = allocateHeader(id: storage.id, kind: .write)

            // Set up offset for positioned I/O
            if storage.offset >= 0 {
                headerPtr.pointee.overlapped.Offset = DWORD(truncatingIfNeeded: storage.offset)
                headerPtr.pointee.overlapped.OffsetHigh = DWORD(truncatingIfNeeded: storage.offset >> 32)
            }

            // Insert into registry BEFORE syscall (precondition: ID is unique)
            state.registry.insert(
                id: storage.id,
                kind: .write,
                resource: .file(fileHandle),
                header: headerPtr
            )

            // Issue syscall
            var bytesWritten: DWORD = 0
            let success = WriteFile(
                fileHandle,
                buffer.baseAddress,
                DWORD(buffer.count),
                &bytesWritten,
                &headerPtr.pointee.overlapped
            )

            if !success {
                let error = GetLastError()
                if error != ERROR_IO_PENDING {
                    // Synchronous failure: remove from registry and deallocate
                    _ = state.registry.remove(id: storage.id)
                    headerPtr.deinitialize(count: 1)
                    headerPtr.deallocate()
                    throw .kernel(.platform(code: Int32(error), message: "WriteFile failed"))
                }
            }
        }

        /// Submits a cancel operation.
        private static func submitCancel(
            _ handle: borrowing IO.Completion.Driver.Handle,
            _ storage: IO.Completion.Operation.Storage,
            _ state: State
        ) throws(IO.Completion.Error) {
            // Target operation ID is encoded in offset field
            let targetID = IO.Completion.ID(UInt64(bitPattern: storage.offset))

            // Peek registry for target (do NOT remove)
            guard let entry = state.registry.peek(id: targetID) else {
                // Already completed or never submitted - not an error
                return
            }

            // Call CancelIoEx with specific overlapped pointer
            if CancelIoEx(entry.resource.handle, entry.overlapped) == 0 {
                let error = GetLastError()
                // ERROR_NOT_FOUND = operation already completed, not an error
                if error != ERROR_NOT_FOUND {
                    throw .kernel(.platform(code: Int32(error), message: "CancelIoEx failed"))
                }
            }
            // Completion (success or cancelled) still arrives via poll
        }

    }

#endif  // os(Windows)
