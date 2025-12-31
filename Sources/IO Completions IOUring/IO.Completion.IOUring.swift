//
//  IO.Completion.IOUring.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 31/12/2025.
//

#if os(Linux)

import Glibc
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
    /// Checks by attempting `io_uring_setup` with minimal parameters.
    /// Result is cached after first call.
    public static var isSupported: Bool {
        _isSupported
    }

    /// Cached support check.
    private static let _isSupported: Bool = {
        // Try to set up a minimal ring to check support
        var params = io_uring_params()
        let fd = io_uring_setup(1, &params)
        if fd >= 0 {
            close(fd)
            return true
        }
        // Check if disabled via environment
        if let env = getenv("IO_URING_DISABLED"), String(cString: env) == "1" {
            return false
        }
        return false
    }()
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

// MARK: - io_uring Syscalls (Raw)

// These are the raw syscall numbers and structures.
// In production, you'd use liburing or a Swift wrapper.

/// io_uring_setup syscall number.
private let SYS_io_uring_setup: Int = 425

/// io_uring_enter syscall number.
private let SYS_io_uring_enter: Int = 426

/// io_uring_register syscall number.
private let SYS_io_uring_register: Int = 427

/// io_uring_params structure.
struct io_uring_params {
    var sq_entries: UInt32 = 0
    var cq_entries: UInt32 = 0
    var flags: UInt32 = 0
    var sq_thread_cpu: UInt32 = 0
    var sq_thread_idle: UInt32 = 0
    var features: UInt32 = 0
    var wq_fd: UInt32 = 0
    var resv: (UInt32, UInt32, UInt32) = (0, 0, 0)
    var sq_off: io_sqring_offsets = io_sqring_offsets()
    var cq_off: io_cqring_offsets = io_cqring_offsets()
}

/// SQ ring offsets.
struct io_sqring_offsets {
    var head: UInt32 = 0
    var tail: UInt32 = 0
    var ring_mask: UInt32 = 0
    var ring_entries: UInt32 = 0
    var flags: UInt32 = 0
    var dropped: UInt32 = 0
    var array: UInt32 = 0
    var resv1: UInt32 = 0
    var resv2: UInt64 = 0
}

/// CQ ring offsets.
struct io_cqring_offsets {
    var head: UInt32 = 0
    var tail: UInt32 = 0
    var ring_mask: UInt32 = 0
    var ring_entries: UInt32 = 0
    var overflow: UInt32 = 0
    var cqes: UInt32 = 0
    var flags: UInt32 = 0
    var resv1: UInt32 = 0
    var resv2: UInt64 = 0
}

/// io_uring_setup wrapper.
private func io_uring_setup(_ entries: UInt32, _ params: inout io_uring_params) -> Int32 {
    Int32(syscall(SYS_io_uring_setup, entries, &params))
}

/// io_uring_enter wrapper.
private func io_uring_enter(
    _ fd: Int32,
    _ toSubmit: UInt32,
    _ minComplete: UInt32,
    _ flags: UInt32
) -> Int32 {
    Int32(syscall(SYS_io_uring_enter, fd, toSubmit, minComplete, flags, nil, 0))
}

// MARK: - Driver Implementation

extension IO.Completion.IOUring {
    /// Creates an io_uring handle.
    static func create(entries: UInt32) throws(IO.Completion.Error) -> IO.Completion.Driver.Handle {
        var params = io_uring_params()

        let fd = io_uring_setup(entries, &params)
        guard fd >= 0 else {
            let error = errno
            throw .kernel(.platform(code: error, message: "io_uring_setup failed"))
        }

        // Map the ring memory
        // In production, this would properly map SQ and CQ rings
        // For now, this is a placeholder

        return IO.Completion.Driver.Handle(
            descriptor: fd,
            ringPtr: nil  // Would be the mmap'd ring memory
        )
    }

    /// Submits operation storage to io_uring.
    static func submitStorage(
        _ handle: borrowing IO.Completion.Driver.Handle,
        _ storage: IO.Completion.Operation.Storage
    ) throws(IO.Completion.Error) {
        guard handle.isIOUring else {
            throw .capability(.backendUnavailable)
        }

        // Fill an SQE based on operation kind
        // This is a placeholder - actual implementation would:
        // 1. Get next SQE from SQ ring
        // 2. Fill fields based on storage.kind
        // 3. Set user_data to storage.userData (pointer recovery)
        // 4. Advance SQ tail

        switch storage.kind {
        case .read:
            // IORING_OP_READ
            break
        case .write:
            // IORING_OP_WRITE
            break
        case .accept:
            // IORING_OP_ACCEPT
            break
        case .connect:
            // IORING_OP_CONNECT
            break
        case .send:
            // IORING_OP_SEND
            break
        case .recv:
            // IORING_OP_RECV
            break
        case .fsync:
            // IORING_OP_FSYNC
            break
        case .close:
            // IORING_OP_CLOSE
            break
        case .cancel:
            // IORING_OP_ASYNC_CANCEL
            break
        case .nop, .wakeup:
            // IORING_OP_NOP
            break
        }
    }

    /// Flushes pending submissions.
    static func flush(_ handle: borrowing IO.Completion.Driver.Handle) throws(IO.Completion.Error) -> Int {
        guard handle.isIOUring else {
            return 0
        }

        // Call io_uring_enter to submit pending SQEs
        let submitted = io_uring_enter(
            handle.descriptor,
            0,  // Would be count of pending SQEs
            0,  // Don't wait for completions
            0   // No flags
        )

        if submitted < 0 {
            let error = errno
            throw .kernel(.platform(code: error, message: "io_uring_enter failed"))
        }

        return Int(submitted)
    }

    /// Polls for completion events.
    static func poll(
        _ handle: borrowing IO.Completion.Driver.Handle,
        _ deadline: IO.Completion.Deadline?,
        _ buffer: inout [IO.Completion.Event]
    ) throws(IO.Completion.Error) -> Int {
        guard handle.isIOUring else {
            return 0
        }

        // In production, this would:
        // 1. Call io_uring_enter with IORING_ENTER_GETEVENTS
        // 2. Read CQEs from CQ ring
        // 3. Convert to IO.Completion.Event
        // 4. Advance CQ head

        // Placeholder implementation
        let minComplete: UInt32 = deadline == nil ? 1 : 0

        let result = io_uring_enter(
            handle.descriptor,
            0,  // No new submissions
            minComplete,
            1   // IORING_ENTER_GETEVENTS
        )

        if result < 0 {
            let error = errno
            if error == EINTR {
                return 0  // Interrupted, retry
            }
            throw .kernel(.platform(code: error, message: "io_uring_enter poll failed"))
        }

        // Would read CQEs here
        return 0
    }

    /// Closes the io_uring handle.
    static func close(_ handle: consuming IO.Completion.Driver.Handle) {
        // Unmap ring memory if present
        // if let ringPtr = handle.ringPtr {
        //     munmap(ringPtr, ringSize)
        // }
        Glibc.close(handle.descriptor)
    }

    /// Creates a wakeup channel for io_uring.
    static func createWakeupChannel(
        _ handle: borrowing IO.Completion.Driver.Handle
    ) throws(IO.Completion.Error) -> IO.Completion.Wakeup.Channel {
        // Use eventfd for wakeup
        let efd = eventfd(0, Int32(EFD_NONBLOCK | EFD_CLOEXEC))
        guard efd >= 0 else {
            let error = errno
            throw .kernel(.platform(code: error, message: "eventfd failed"))
        }

        return IO.Completion.Wakeup.Channel(
            wake: {
                var value: UInt64 = 1
                _ = write(efd, &value, 8)
            },
            close: {
                Glibc.close(efd)
            }
        )
    }
}

#endif // os(Linux)
