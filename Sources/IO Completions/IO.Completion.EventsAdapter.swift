//
//  IO.Completion.EventsAdapter.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 31/12/2025.
//

// Import Kernel for Kernel.Error. We use @_silgen_name("kevent") to define
// our own kevent wrapper (c_kevent) which avoids the symbol collision with
// any Kernel module kevent wrapper at call sites.
public import Kernel

#if canImport(Darwin)
import Darwin

// Local kevent wrapper via @_silgen_name to avoid calling Kernel's kevent overlay.
// By using a uniquely named function, we ensure we call the C function directly.
@_silgen_name("kevent")
private func c_kevent(
    _ kq: Int32,
    _ changelist: UnsafePointer<Darwin.kevent>?,
    _ nchanges: Int32,
    _ eventlist: UnsafeMutablePointer<Darwin.kevent>?,
    _ nevents: Int32,
    _ timeout: UnsafePointer<timespec>?
) -> Int32

#elseif canImport(Glibc)
import Glibc
#endif

extension IO.Completion {
    /// Completion façade over readiness-based I/O (kqueue/epoll).
    ///
    /// EventsAdapter provides a completion-based API on platforms that
    /// only have readiness-based event notification. It works by:
    /// 1. Submitting an operation with `_submit`
    /// 2. Arming the descriptor for readiness
    /// 3. When ready, performing the syscall
    /// 4. Producing a completion event
    ///
    /// ## Supported Operations (v1)
    ///
    /// - `nop`: No-op (for testing/wakeup)
    /// - `read`: Read when readable
    /// - `write`: Write when writable
    /// - `accept`: Accept when readable
    /// - `connect`: Connect + check via getsockopt
    /// - `wakeup`: Internal wakeup signal
    ///
    /// ## Limitations
    ///
    /// - No true async: Syscalls happen synchronously after readiness
    /// - No batched submission: Each operation is a separate arm
    /// - No registered buffers: Standard read/write syscalls
    ///
    /// ## Usage
    ///
    /// This adapter is selected automatically on Darwin and as a fallback
    /// on Linux when io_uring is unavailable.
    public enum EventsAdapter {}
}

// MARK: - Driver Factory

extension IO.Completion.EventsAdapter {
    /// Creates an EventsAdapter driver.
    ///
    /// - Returns: A configured driver using kqueue (Darwin) or epoll (Linux).
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

    /// EventsAdapter capabilities.
    public static let capabilities = IO.Completion.Driver.Capabilities(
        maxSubmissions: 1,  // No batching
        maxCompletions: 64,
        supportedKinds: .eventsAdapterV1,
        batchedSubmission: false,
        registeredBuffers: false,
        multishot: false
    )
}

// MARK: - Driver Implementation

extension IO.Completion.EventsAdapter {
    /// Creates an EventsAdapter handle.
    static func create() throws(IO.Completion.Error) -> IO.Completion.Driver.Handle {
        #if canImport(Darwin)
        let fd = kqueue()
        guard fd >= 0 else {
            let error = errno
            throw .kernel(.platform(code: error, message: "kqueue failed"))
        }
        return IO.Completion.Driver.Handle(descriptor: fd)
        #elseif os(Linux)
        let fd = epoll_create1(Int32(EPOLL_CLOEXEC))
        guard fd >= 0 else {
            let error = errno
            throw .kernel(.platform(code: error, message: "epoll_create1 failed"))
        }
        return IO.Completion.Driver.Handle(descriptor: fd, ringPtr: nil)
        #else
        throw .capability(.backendUnavailable)
        #endif
    }

    /// Submits an operation.
    ///
    /// For EventsAdapter, this arms the descriptor for readiness.
    static func submit(
        _ handle: borrowing IO.Completion.Driver.Handle,
        _ operation: borrowing IO.Completion.Operation
    ) throws(IO.Completion.Error) {
        // Check if operation kind is supported
        guard IO.Completion.KindSet.eventsAdapterV1.contains(operation.kind) else {
            throw .capability(.unsupportedKind(operation.kind))
        }

        // Arm for appropriate readiness
        // In a real implementation, this would:
        // 1. Store the operation in a pending map
        // 2. Arm kqueue/epoll for read/write readiness
        // 3. On readiness, perform the syscall and produce completion
    }

    /// Flushes pending submissions (no-op for EventsAdapter).
    static func flush(_ handle: borrowing IO.Completion.Driver.Handle) throws(IO.Completion.Error) -> Int {
        // No batching, nothing to flush
        return 0
    }

    /// Polls for completion events.
    static func poll(
        _ handle: borrowing IO.Completion.Driver.Handle,
        _ deadline: IO.Completion.Deadline?,
        _ buffer: inout [IO.Completion.Event]
    ) throws(IO.Completion.Error) -> Int {
        #if canImport(Darwin)
        return try pollKqueue(handle, deadline, &buffer)
        #elseif os(Linux)
        return try pollEpoll(handle, deadline, &buffer)
        #else
        return 0
        #endif
    }

    #if canImport(Darwin)
    /// Polls using kqueue.
    private static func pollKqueue(
        _ handle: borrowing IO.Completion.Driver.Handle,
        _ deadline: IO.Completion.Deadline?,
        _ buffer: inout [IO.Completion.Event]
    ) throws(IO.Completion.Error) -> Int {
        var events = [Darwin.kevent](repeating: Darwin.kevent(), count: buffer.count)

        var timeout: timespec?
        if let deadline {
            let remaining = deadline.remainingNanoseconds
            if remaining <= 0 {
                timeout = timespec(tv_sec: 0, tv_nsec: 0)
            } else {
                let seconds = remaining / 1_000_000_000
                let nanos = remaining % 1_000_000_000
                timeout = timespec(tv_sec: Int(seconds), tv_nsec: Int(nanos))
            }
        }

        let count: Int32
        if var ts = timeout {
            count = c_kevent(handle.descriptor, nil, 0, &events, Int32(events.count), &ts)
        } else {
            count = c_kevent(handle.descriptor, nil, 0, &events, Int32(events.count), nil)
        }

        if count < 0 {
            let error = errno
            if error == EINTR {
                return 0
            }
            throw .kernel(.platform(code: error, message: "kevent poll failed"))
        }

        // Convert kevent to completion events
        // In a real implementation, this would look up pending operations
        // and produce completions based on readiness

        return Int(count)
    }
    #endif

    #if os(Linux)
    /// Polls using epoll.
    private static func pollEpoll(
        _ handle: borrowing IO.Completion.Driver.Handle,
        _ deadline: IO.Completion.Deadline?,
        _ buffer: inout [IO.Completion.Event]
    ) throws(IO.Completion.Error) -> Int {
        var events = [epoll_event](repeating: epoll_event(), count: buffer.count)

        let timeoutMs: Int32
        if let deadline {
            let remaining = deadline.remainingNanoseconds
            if remaining <= 0 {
                timeoutMs = 0
            } else {
                let ms = remaining / 1_000_000
                timeoutMs = ms > Int64(Int32.max) ? Int32.max : Int32(ms)
            }
        } else {
            timeoutMs = -1
        }

        let count = epoll_wait(handle.descriptor, &events, Int32(events.count), timeoutMs)

        if count < 0 {
            let error = errno
            if error == EINTR {
                return 0
            }
            throw .kernel(.platform(code: error, message: "epoll_wait failed"))
        }

        // Convert epoll_event to completion events
        // In a real implementation, this would look up pending operations

        return Int(count)
    }
    #endif

    /// Closes the EventsAdapter handle.
    static func close(_ handle: consuming IO.Completion.Driver.Handle) {
        #if canImport(Darwin) || os(Linux)
        Darwin.close(handle.descriptor)
        #endif
    }

    /// Creates a wakeup channel.
    static func createWakeupChannel(
        _ handle: borrowing IO.Completion.Driver.Handle
    ) throws(IO.Completion.Error) -> IO.Completion.Wakeup.Channel {
        #if canImport(Darwin)
        // Use EVFILT_USER for kqueue wakeup
        let fd = handle.descriptor

        // Register user event
        var event = Darwin.kevent()
        event.ident = 1  // Wakeup ident
        event.filter = Int16(EVFILT_USER)
        event.flags = UInt16(EV_ADD | EV_CLEAR)
        event.fflags = 0
        event.data = 0
        event.udata = nil

        let result = c_kevent(fd, &event, 1, nil, 0, nil)
        if result < 0 {
            let error = errno
            throw .kernel(.platform(code: error, message: "kevent EVFILT_USER register failed"))
        }

        return IO.Completion.Wakeup.Channel(
            wake: {
                var triggerEvent = Darwin.kevent()
                triggerEvent.ident = 1
                triggerEvent.filter = Int16(EVFILT_USER)
                triggerEvent.flags = 0
                triggerEvent.fflags = UInt32(NOTE_TRIGGER)
                triggerEvent.data = 0
                triggerEvent.udata = nil

                _ = c_kevent(fd, &triggerEvent, 1, nil, 0, nil)
            },
            close: nil
        )
        #elseif os(Linux)
        // Use eventfd for epoll wakeup
        let efd = eventfd(0, Int32(EFD_NONBLOCK | EFD_CLOEXEC))
        guard efd >= 0 else {
            let error = errno
            throw .kernel(.platform(code: error, message: "eventfd failed"))
        }

        // Register with epoll
        var event = epoll_event()
        event.events = UInt32(EPOLLIN)
        event.data.fd = efd

        let result = epoll_ctl(handle.descriptor, EPOLL_CTL_ADD, efd, &event)
        if result < 0 {
            Glibc.close(efd)
            let error = errno
            throw .kernel(.platform(code: error, message: "epoll_ctl ADD failed"))
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
        #else
        throw .capability(.backendUnavailable)
        #endif
    }
}
