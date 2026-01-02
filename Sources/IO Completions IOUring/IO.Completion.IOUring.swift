//
//  IO.Completion.IOUring.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 31/12/2025.
//

#if os(Linux)

    public import Kernel
    import MMap
    @_exported public import IO_Completions_Driver

    extension IO.Completion {
        /// Linux io_uring backend.
        ///
        /// io_uring is Linux's modern async I/O interface (kernel 5.1+).
        /// It provides:
        /// - True async I/O at the kernel level
        /// - Batched submission and completion
        /// - Zero-copy with registered buffers
        /// - Multishot operations (5.19+)
        ///
        /// ## Runtime Detection
        ///
        /// The `isSupported` property checks if io_uring is available at runtime.
        /// If not available, `Driver.bestAvailable()` throws `.capability(.backendUnavailable)`.
        ///
        /// ## Design
        ///
        /// Uses the SQ/CQ ring buffer model:
        /// - SQ (Submission Queue): Client fills SQEs, kernel consumes
        /// - CQ (Completion Queue): Kernel fills CQEs, client consumes
        ///
        /// ## Thread Safety
        ///
        /// - SQ access: Single producer (poll thread)
        /// - CQ access: Single consumer (poll thread)
        /// - Ring memory: Shared with kernel via mmap
        public enum IOUring {}
    }

    // MARK: - Runtime Detection

    extension IO.Completion.IOUring {
        /// Whether io_uring is available on this system.
        ///
        /// Delegates to `Kernel.IOUring.isSupported`.
        public static var isSupported: Bool {
            Kernel.IOUring.isSupported
        }
    }

    // MARK: - Driver Factory

    extension IO.Completion.IOUring {
        /// Creates an io_uring driver instance.
        ///
        /// - Parameter entries: Ring size (power of 2, typically 128-4096).
        /// - Returns: A configured driver for io_uring.
        /// - Throws: If io_uring setup fails.
        public static func driver(entries: UInt32 = 256) throws(IO.Completion.Error) -> IO.Completion.Driver {
            guard isSupported else {
                throw .capability(.backendUnavailable)
            }

            return IO.Completion.Driver(
                capabilities: capabilities(entries: entries),
                create: { try create(entries: entries) },
                submitStorage: submitStorage,
                flush: flush,
                poll: poll,
                close: close,
                createWakeupChannel: createWakeupChannel
            )
        }

        /// io_uring capabilities for a given ring size.
        public static func capabilities(entries: UInt32) -> IO.Completion.Driver.Capabilities {
            IO.Completion.Driver.Capabilities(
                maxSubmissions: Int(entries),
                maxCompletions: Int(entries * 2),  // CQ is typically 2x SQ
                supportedKinds: .iouring,
                batchedSubmission: true,
                registeredBuffers: true,  // IORING_REGISTER_BUFFERS
                multishot: kernelSupportsMultishot
            )
        }

        /// Whether kernel supports multishot operations.
        private static let kernelSupportsMultishot: Bool = {
            // Multishot accept was added in kernel 5.19
            // This would require checking kernel version or probing
            // For now, assume not supported
            false
        }()
    }

    // MARK: - Driver Implementation

    extension IO.Completion.IOUring {
        /// Creates an io_uring handle.
        static func create(entries: UInt32) throws(IO.Completion.Error) -> IO.Completion.Driver.Handle {
            var params = Kernel.IOUring.Params()

            let fd: Kernel.Descriptor
            do {
                fd = try Kernel.IOUring.setup(entries: entries, params: &params)
            } catch let error as Kernel.IOUring.Error {
                throw .kernel(error.asKernelError)
            }

            // Create ring state with mmap'd memory
            let ring: Ring
            do {
                ring = try Ring(fd: fd, params: params)
            } catch {
                Kernel.IOUring.close(fd)
                throw error
            }

            // Store ring pointer in handle
            let ringPtr = Unmanaged.passRetained(ring).toOpaque()

            return IO.Completion.Driver.Handle(
                descriptor: fd.rawValue,
                ringPtr: ringPtr
            )
        }

        /// Gets the Ring from a handle.
        @inline(__always)
        private static func getRing(from handle: borrowing IO.Completion.Driver.Handle) -> Ring {
            Unmanaged<Ring>.fromOpaque(handle.ringPtr!).takeUnretainedValue()
        }

        /// Submits operation storage to io_uring.
        static func submitStorage(
            _ handle: borrowing IO.Completion.Driver.Handle,
            _ storage: IO.Completion.Operation.Storage
        ) throws(IO.Completion.Error) {
            guard handle.ringPtr != nil else {
                throw .capability(.backendUnavailable)
            }

            let ring = getRing(from: handle)

            // Get next SQE slot
            guard let sqePtr = ring.getNextSQE() else {
                throw .operation(.queueFull)
            }

            // Zero the SQE first
            sqePtr.pointee = io_uring_sqe()

            // Fill based on operation kind
            switch storage.kind {
            case .read:
                sqePtr.pointee.opcode = Kernel.IOUring.Opcode.read.rawValue
                sqePtr.pointee.fd = storage.descriptor.rawValue
                if storage.offset >= 0 {
                    sqePtr.pointee.off = UInt64(bitPattern: storage.offset)
                } else {
                    sqePtr.pointee.off = UInt64.max  // Use current file position
                }
                if let buffer = storage.buffer {
                    sqePtr.pointee.addr = UInt64(UInt(bitPattern: buffer.baseAddress))
                    sqePtr.pointee.len = UInt32(buffer.count)
                }
                sqePtr.pointee.user_data = storage.userData

            case .write:
                sqePtr.pointee.opcode = Kernel.IOUring.Opcode.write.rawValue
                sqePtr.pointee.fd = storage.descriptor.rawValue
                if storage.offset >= 0 {
                    sqePtr.pointee.off = UInt64(bitPattern: storage.offset)
                } else {
                    sqePtr.pointee.off = UInt64.max
                }
                if let buffer = storage.buffer {
                    sqePtr.pointee.addr = UInt64(UInt(bitPattern: buffer.baseAddress))
                    sqePtr.pointee.len = UInt32(buffer.count)
                }
                sqePtr.pointee.user_data = storage.userData

            case .fsync:
                sqePtr.pointee.opcode = Kernel.IOUring.Opcode.fsync.rawValue
                sqePtr.pointee.fd = storage.descriptor.rawValue
                sqePtr.pointee.user_data = storage.userData

            case .close:
                sqePtr.pointee.opcode = Kernel.IOUring.Opcode.close.rawValue
                sqePtr.pointee.fd = storage.descriptor.rawValue
                sqePtr.pointee.user_data = storage.userData

            case .cancel:
                sqePtr.pointee.opcode = Kernel.IOUring.Opcode.asyncCancel.rawValue
                // Target user_data is stored in offset field for cancel operations
                sqePtr.pointee.addr = UInt64(bitPattern: storage.offset)
                sqePtr.pointee.user_data = storage.userData

            case .nop, .wakeup:
                sqePtr.pointee.opcode = Kernel.IOUring.Opcode.nop.rawValue
                sqePtr.pointee.user_data = storage.userData

            case .accept, .connect, .send, .recv:
                // Socket operations deferred to swift-sockets
                throw .capability(.unsupportedKind(storage.kind))
            }

            // Advance the SQ tail
            ring.advanceSQTail()
        }

        /// Flushes pending submissions.
        static func flush(_ handle: borrowing IO.Completion.Driver.Handle) throws(IO.Completion.Error) -> Int {
            guard handle.ringPtr != nil else {
                return 0
            }

            let ring = getRing(from: handle)

            let toSubmit = ring.pendingSubmissions
            guard toSubmit > 0 else { return 0 }

            // Write memory barrier then update kernel-visible tail
            Kernel.Atomic.store(ring.sqTail, ring.localSqTail, ordering: .releasing)

            // Call io_uring_enter to submit
            do {
                let submitted = try Kernel.IOUring.enter(
                    ring.fd,
                    toSubmit: toSubmit,
                    minComplete: 0,
                    flags: []
                )
                return submitted
            } catch let error as Kernel.IOUring.Error {
                if case .interrupted = error {
                    return 0  // Interrupted, caller should retry
                }
                throw .kernel(error.asKernelError)
            }
        }

        /// Polls for completion events.
        static func poll(
            _ handle: borrowing IO.Completion.Driver.Handle,
            _ deadline: IO.Completion.Deadline?,
            _ buffer: inout [IO.Completion.Event]
        ) throws(IO.Completion.Error) -> Int {
            guard handle.ringPtr != nil else {
                return 0
            }

            let ring = getRing(from: handle)

            // Read CQ head/tail with memory barriers
            var head = Kernel.Atomic.load(ring.cqHead, ordering: .acquiring)
            var tail = Kernel.Atomic.load(ring.cqTail, ordering: .acquiring)

            if head == tail {
                // No completions available, wait via io_uring_enter
                let minComplete: UInt32 = deadline == nil ? 1 : 0

                do {
                    _ = try Kernel.IOUring.enter(
                        ring.fd,
                        toSubmit: 0,
                        minComplete: minComplete,
                        flags: .getEvents
                    )
                } catch let error as Kernel.IOUring.Error {
                    if case .interrupted = error {
                        return 0  // Interrupted, caller should retry
                    }
                    throw .kernel(error.asKernelError)
                }

                // Re-read tail after waiting
                tail = Kernel.Atomic.load(ring.cqTail, ordering: .acquiring)
            }

            // Read CQEs
            var count = 0
            let maxEvents = buffer.capacity - buffer.count

            while head != tail && count < maxEvents {
                let index = head & ring.cqMask
                let cqe = Kernel.IOUring.CQE(ring.cqes[Int(index)])

                // Convert CQE to Event
                let userData = cqe.userData
                let res = cqe.res

                // Recover Storage from user_data pointer to get operation details
                guard let storagePtr = UnsafeRawPointer(bitPattern: UInt(userData)) else {
                    // Invalid user_data, skip
                    head &+= 1
                    continue
                }
                let storage = Unmanaged<IO.Completion.Operation.Storage>.fromOpaque(storagePtr).takeUnretainedValue()

                let outcome: IO.Completion.Outcome
                if cqe.isSuccess {
                    switch storage.kind {
                    case .read, .write, .send, .recv:
                        outcome = .success(.bytes(Int(res)))
                    case .connect:
                        outcome = .success(.connected)
                    case .accept:
                        // For accept, res contains the new fd
                        outcome = .success(.accepted(descriptor: Kernel.Descriptor(rawValue: res)))
                    default:
                        outcome = .success(.completed)
                    }
                } else if cqe.isCancelled {
                    outcome = .cancelled
                } else {
                    outcome = .failure(.platform(code: -res, message: "io_uring operation failed"))
                }

                buffer.append(
                    IO.Completion.Event(
                        id: storage.id,
                        kind: storage.kind,
                        outcome: outcome,
                        userData: userData
                    )
                )

                head &+= 1
                count += 1
            }

            // Update CQ head with memory barrier
            Kernel.Atomic.store(ring.cqHead, head, ordering: .releasing)

            return count
        }

        /// Closes the io_uring handle.
        static func close(_ handle: consuming IO.Completion.Driver.Handle) {
            if let ringPtr = handle.ringPtr {
                // Take retained value - this will trigger Ring deinit which closes fd and unmaps memory
                _ = Unmanaged<Ring>.fromOpaque(ringPtr).takeRetainedValue()
            } else {
                // No ring, just close the fd
                try? Kernel.Close.close(Kernel.Descriptor(rawValue: handle.descriptor))
            }
        }

        /// Creates a wakeup channel for io_uring.
        static func createWakeupChannel(
            _ handle: borrowing IO.Completion.Driver.Handle
        ) throws(IO.Completion.Error) -> IO.Completion.Wakeup.Channel {
            // Use eventfd for wakeup
            let efd: Kernel.Descriptor
            do {
                efd = try Kernel.Eventfd.create(flags: .cloexec | .nonblock)
            } catch let error as Kernel.Eventfd.Error {
                throw .kernel(error.asKernelError)
            }

            return IO.Completion.Wakeup.Channel(
                wake: {
                    Kernel.Eventfd.signal(efd)
                },
                close: {
                    try? Kernel.Close.close(efd)
                }
            )
        }
    }

#endif  // os(Linux)
