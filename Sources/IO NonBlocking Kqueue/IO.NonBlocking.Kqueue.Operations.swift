//
//  IO.NonBlocking.Kqueue.Operations.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 28/12/2025.
//

#if canImport(Darwin)

import Darwin.C
import Synchronization

// Import the kevent function explicitly (not the struct)
@_silgen_name("kevent")
private func kevent_c(
    _ kq: Int32,
    _ changelist: UnsafePointer<Darwin.kevent>?,
    _ nchanges: Int32,
    _ eventlist: UnsafeMutablePointer<Darwin.kevent>?,
    _ nevents: Int32,
    _ timeout: UnsafePointer<timespec>?
) -> Int32

/// Internal implementation of kqueue operations.
enum KqueueOperations {
    /// Counter for generating unique registration IDs.
    private static let nextID = Atomic<UInt64>(0)

    /// Creates a new kqueue handle.
    static func create() throws -> IO.NonBlocking.Driver.Handle {
        let kq = Darwin.kqueue()
        guard kq >= 0 else {
            throw IO.NonBlocking.Error.platform(errno: errno)
        }
        return IO.NonBlocking.Driver.Handle(rawValue: kq)
    }

    /// Registers a file descriptor with the kqueue.
    static func register(
        _ handle: borrowing IO.NonBlocking.Driver.Handle,
        descriptor: Int32,
        interest: IO.NonBlocking.Interest
    ) throws -> IO.NonBlocking.ID {
        let id = IO.NonBlocking.ID(raw: nextID.wrappingAdd(1, ordering: .relaxed).newValue)

        // Prepare kevent structures for registration
        var events: [Darwin.kevent] = []

        if interest.contains(.read) {
            var ev = Darwin.kevent()
            ev.ident = UInt(descriptor)
            ev.filter = Int16(EVFILT_READ)
            ev.flags = UInt16(EV_ADD | EV_CLEAR)  // Edge-triggered
            ev.fflags = 0
            ev.data = 0
            ev.udata = UnsafeMutableRawPointer(bitPattern: UInt(id.raw))
            events.append(ev)
        }

        if interest.contains(.write) {
            var ev = Darwin.kevent()
            ev.ident = UInt(descriptor)
            ev.filter = Int16(EVFILT_WRITE)
            ev.flags = UInt16(EV_ADD | EV_CLEAR)  // Edge-triggered
            ev.fflags = 0
            ev.data = 0
            ev.udata = UnsafeMutableRawPointer(bitPattern: UInt(id.raw))
            events.append(ev)
        }

        guard !events.isEmpty else {
            return id
        }

        let result = events.withUnsafeBufferPointer { ptr in
            kevent_c(handle.rawValue, ptr.baseAddress, Int32(ptr.count), nil, 0, nil)
        }
        if result < 0 {
            throw IO.NonBlocking.Error.platform(errno: errno)
        }

        return id
    }

    /// Modifies the interests for a registration.
    static func modify(
        _ handle: borrowing IO.NonBlocking.Driver.Handle,
        id: IO.NonBlocking.ID,
        interest: IO.NonBlocking.Interest
    ) throws {
        // For kqueue, modification is done by re-adding with new flags
        // We need the original descriptor, which we'd need to track
        // For now, this is a simplified implementation
        // In a full implementation, we'd maintain a mapping of ID -> descriptor
    }

    /// Deregisters a file descriptor.
    static func deregister(
        _ handle: borrowing IO.NonBlocking.Driver.Handle,
        id: IO.NonBlocking.ID
    ) throws {
        // For kqueue, events are automatically removed when the fd is closed
        // Explicit removal would require tracking ID -> descriptor mapping
    }

    /// Polls for events.
    static func poll(
        _ handle: borrowing IO.NonBlocking.Driver.Handle,
        deadline: IO.NonBlocking.Deadline?,
        into buffer: inout [IO.NonBlocking.Event]
    ) throws -> Int {
        var timeout: timespec?

        if let deadline = deadline {
            // Calculate timeout from deadline
            let now = getMonotonicTime()
            let deadlineNanos = Int64(bitPattern: deadline.nanoseconds)
            let remaining = deadlineNanos - now
            if remaining <= 0 {
                // Already expired
                timeout = timespec(tv_sec: 0, tv_nsec: 0)
            } else {
                timeout = timespec(
                    tv_sec: Int(remaining / 1_000_000_000),
                    tv_nsec: Int(remaining % 1_000_000_000)
                )
            }
        }

        // Create a buffer for raw kevent structures
        var rawEvents = [Darwin.kevent](repeating: Darwin.kevent(), count: buffer.count)

        let count: Int32
        if var ts = timeout {
            count = rawEvents.withUnsafeMutableBufferPointer { evPtr in
                withUnsafePointer(to: &ts) { tsPtr in
                    kevent_c(
                        handle.rawValue,
                        nil,
                        0,
                        evPtr.baseAddress,
                        Int32(evPtr.count),
                        tsPtr
                    )
                }
            }
        } else {
            count = rawEvents.withUnsafeMutableBufferPointer { evPtr in
                kevent_c(
                    handle.rawValue,
                    nil,
                    0,
                    evPtr.baseAddress,
                    Int32(evPtr.count),
                    nil
                )
            }
        }

        if count < 0 {
            let err = errno
            if err == EINTR {
                return 0  // Interrupted, return 0 events
            }
            throw IO.NonBlocking.Error.platform(errno: err)
        }

        // Convert raw events to IO.NonBlocking.Event
        var outputIndex = 0
        for i in 0..<Int(count) {
            let raw = rawEvents[i]

            // Skip user events (wakeup)
            if raw.filter == Int16(EVFILT_USER) {
                continue
            }

            let id = IO.NonBlocking.ID(raw: UInt64(UInt(bitPattern: raw.udata)))

            var interest: IO.NonBlocking.Interest = []
            if raw.filter == Int16(EVFILT_READ) {
                interest.insert(.read)
            }
            if raw.filter == Int16(EVFILT_WRITE) {
                interest.insert(.write)
            }

            var flags: IO.NonBlocking.Event.Flags = []
            if raw.flags & UInt16(EV_EOF) != 0 {
                flags.insert(.hangup)
                if raw.filter == Int16(EVFILT_READ) {
                    flags.insert(.readHangup)
                } else if raw.filter == Int16(EVFILT_WRITE) {
                    flags.insert(.writeHangup)
                }
            }
            if raw.flags & UInt16(EV_ERROR) != 0 {
                flags.insert(.error)
            }

            buffer[outputIndex] = IO.NonBlocking.Event(id: id, interest: interest, flags: flags)
            outputIndex += 1
        }

        return outputIndex
    }

    /// Closes the kqueue handle.
    static func close(_ handle: consuming IO.NonBlocking.Driver.Handle) {
        Darwin.close(handle.rawValue)
    }

    /// Creates a wakeup channel using EVFILT_USER.
    static func createWakeupChannel(
        _ handle: borrowing IO.NonBlocking.Driver.Handle
    ) throws -> IO.NonBlocking.Wakeup.Channel {
        // Register a user event for wakeup
        let wakeupIdent: UInt = 1  // Special ident for wakeup

        var ev = Darwin.kevent()
        ev.ident = wakeupIdent
        ev.filter = Int16(EVFILT_USER)
        ev.flags = UInt16(EV_ADD | EV_CLEAR)
        ev.fflags = 0
        ev.data = 0
        ev.udata = nil

        let result = withUnsafePointer(to: &ev) { ptr in
            kevent_c(handle.rawValue, ptr, 1, nil, 0, nil)
        }
        if result < 0 {
            throw IO.NonBlocking.Error.platform(errno: errno)
        }

        // Capture the kqueue fd for the wakeup channel
        let kq = handle.rawValue

        return IO.NonBlocking.Wakeup.Channel {
            // Trigger the user event
            var triggerEv = Darwin.kevent()
            triggerEv.ident = wakeupIdent
            triggerEv.filter = Int16(EVFILT_USER)
            triggerEv.flags = 0
            triggerEv.fflags = UInt32(NOTE_TRIGGER)
            triggerEv.data = 0
            triggerEv.udata = nil

            _ = withUnsafePointer(to: &triggerEv) { ptr in
                kevent_c(kq, ptr, 1, nil, 0, nil)
            }
        }
    }

    /// Gets the current monotonic time in nanoseconds.
    private static func getMonotonicTime() -> Int64 {
        var ts = timespec()
        clock_gettime(CLOCK_MONOTONIC, &ts)
        return Int64(ts.tv_sec) * 1_000_000_000 + Int64(ts.tv_nsec)
    }
}

#endif
