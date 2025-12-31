//
//  IO.Completion.IOCP.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 31/12/2025.
//

#if os(Windows)

import WinSDK
@_exported public import IO_Completions_Driver

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
    /// ## Thread Safety
    ///
    /// - `PostQueuedCompletionStatus`: Thread-safe (for wakeup)
    /// - `GetQueuedCompletionStatusEx`: Single-consumer (poll thread)
    /// - Handle association: Once per descriptor (tracked via registry)
    public enum IOCP {}
}

// MARK: - Driver Factory

extension IO.Completion.IOCP {
    /// Creates an IOCP driver instance.
    ///
    /// - Returns: A configured driver for Windows IOCP.
    public static func driver() -> IO.Completion.Driver {
        IO.Completion.Driver(
            capabilities: capabilities,
            create: create,
            submit: submit,
            flush: flush,
            poll: poll,
            close: close,
            createWakeupChannel: createWakeupChannel
        )
    }

    /// IOCP capabilities.
    public static let capabilities = IO.Completion.Driver.Capabilities(
        maxSubmissions: Int.max,  // No batching, immediate submission
        maxCompletions: 64,       // GetQueuedCompletionStatusEx batch size
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
        let handle = CreateIoCompletionPort(
            INVALID_HANDLE_VALUE,
            nil,
            0,
            0  // Use default number of concurrent threads
        )

        guard let handle, handle != INVALID_HANDLE_VALUE else {
            let error = GetLastError()
            throw .kernel(.platform(code: Int32(error), message: "CreateIoCompletionPort failed"))
        }

        return IO.Completion.Driver.Handle(raw: handle)
    }

    /// Submits an operation to IOCP.
    static func submit(
        _ handle: borrowing IO.Completion.Driver.Handle,
        _ operation: borrowing IO.Completion.Operation
    ) throws(IO.Completion.Error) {
        // IOCP requires per-descriptor association before I/O
        // This is handled by the higher-level Queue which tracks associations

        // For now, this is a placeholder. The actual implementation would:
        // 1. Check/perform handle association with the IOCP
        // 2. Call the appropriate async Win32 API (ReadFile, WriteFile, etc.)
        // 3. Pass the OVERLAPPED pointer from operation.storage

        // Implementation depends on operation kind
        switch operation.kind {
        case .read:
            try submitRead(handle, operation)
        case .write:
            try submitWrite(handle, operation)
        case .accept:
            try submitAccept(handle, operation)
        case .connect:
            try submitConnect(handle, operation)
        case .nop, .wakeup:
            // Handled via PostQueuedCompletionStatus
            break
        case .cancel:
            try submitCancel(handle, operation)
        default:
            throw .capability(.unsupportedKind(operation.kind))
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
        _ buffer: inout [IO.Completion.Event]
    ) throws(IO.Completion.Error) -> Int {
        var entries = [OVERLAPPED_ENTRY](repeating: OVERLAPPED_ENTRY(), count: buffer.count)
        var numRemoved: ULONG = 0

        let timeout: DWORD
        if let deadline {
            let remaining = deadline.remainingNanoseconds
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

            // Check for wakeup sentinel (completion key == 0, no overlapped)
            if entry.lpCompletionKey == 0 && entry.lpOverlapped == nil {
                buffer[i] = IO.Completion.Event(
                    id: IO.Completion.ID(raw: 0),
                    kind: .wakeup,
                    result: .success(.completed)
                )
                continue
            }

            // Recover Header from OVERLAPPED pointer using container-of
            guard let overlapped = entry.lpOverlapped else { continue }
            let header = Header.from(overlapped: overlapped)

            // Build result from header
            let result: IO.Completion.Result
            if header.error == 0 {
                result = .success(.bytes(Int(header.bytes)))
            } else {
                result = .failure(.platform(
                    code: Int32(header.error),
                    message: "IOCP operation failed"
                ))
            }

            buffer[i] = IO.Completion.Event(
                id: header.id,
                kind: header.kind,
                result: result,
                userData: UInt64(UInt(bitPattern: overlapped))
            )
        }

        return Int(numRemoved)
    }

    /// Closes the IOCP handle.
    static func close(_ handle: consuming IO.Completion.Driver.Handle) {
        CloseHandle(handle.raw)
    }

    /// Creates a wakeup channel for IOCP.
    static func createWakeupChannel(
        _ handle: borrowing IO.Completion.Driver.Handle
    ) throws(IO.Completion.Error) -> IO.Completion.Wakeup.Channel {
        // Capture the raw handle pointer for the wakeup closure
        let rawHandle = handle.raw

        return IO.Completion.Wakeup.Channel(
            wake: {
                // Post a completion with key=0 and no overlapped as wakeup sentinel
                PostQueuedCompletionStatus(rawHandle, 0, 0, nil)
            },
            close: nil  // No cleanup needed
        )
    }
}

// MARK: - Operation Submissions

extension IO.Completion.IOCP {
    /// Submits a read operation.
    private static func submitRead(
        _ handle: borrowing IO.Completion.Driver.Handle,
        _ operation: borrowing IO.Completion.Operation
    ) throws(IO.Completion.Error) {
        // Placeholder - actual implementation would:
        // 1. Set up OVERLAPPED with offset
        // 2. Call ReadFile with operation.storage.buffer
        // 3. Handle ERROR_IO_PENDING
    }

    /// Submits a write operation.
    private static func submitWrite(
        _ handle: borrowing IO.Completion.Driver.Handle,
        _ operation: borrowing IO.Completion.Operation
    ) throws(IO.Completion.Error) {
        // Placeholder - actual implementation would:
        // 1. Set up OVERLAPPED with offset
        // 2. Call WriteFile with operation.storage.buffer
        // 3. Handle ERROR_IO_PENDING
    }

    /// Submits an accept operation.
    private static func submitAccept(
        _ handle: borrowing IO.Completion.Driver.Handle,
        _ operation: borrowing IO.Completion.Operation
    ) throws(IO.Completion.Error) {
        // Placeholder - actual implementation would:
        // 1. Create accept socket
        // 2. Allocate address buffer
        // 3. Call AcceptEx
    }

    /// Submits a connect operation.
    private static func submitConnect(
        _ handle: borrowing IO.Completion.Driver.Handle,
        _ operation: borrowing IO.Completion.Operation
    ) throws(IO.Completion.Error) {
        // Placeholder - actual implementation would:
        // 1. Call ConnectEx with address
        // 2. Handle ERROR_IO_PENDING
    }

    /// Submits a cancel operation.
    private static func submitCancel(
        _ handle: borrowing IO.Completion.Driver.Handle,
        _ operation: borrowing IO.Completion.Operation
    ) throws(IO.Completion.Error) {
        // Placeholder - actual implementation would:
        // 1. Recover target operation's OVERLAPPED
        // 2. Call CancelIoEx
    }
}

#endif // os(Windows)
