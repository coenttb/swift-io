//
//  IO.Event.Kqueue.Operations.swift
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

// MARK: - Registration Mapping

/// Per-registration state tracking descriptor and current interests.
private struct RegistrationEntry: Sendable {
    let descriptor: Int32
    var interest: IO.Event.Interest
}

/// Module-level registry mapping kqueue fd → (ID → registration).
///
/// Thread-safe via Mutex. Each kqueue's entries are accessed only by its poll thread,
/// so contention is minimal (only during concurrent Selector creation/destruction).
private let registry = Mutex<[Int32: [IO.Event.ID: RegistrationEntry]]>([:])

/// Internal implementation of kqueue operations.
enum KqueueOperations {
    /// Counter for generating unique registration IDs.
    ///
    /// ## Global State (PATTERN REQUIREMENTS §6.6)
    /// This is an intentional process-global atomic counter. Rationale:
    /// - Each registration needs a unique ID across all kqueue instances
    /// - Atomic increment is lock-free and thread-safe
    /// - Wrapping at UInt64.max is acceptable (would require ~600 years at 1M/sec)
    private static let nextID = Atomic<UInt64>(0)

    /// Creates a new kqueue handle.
    static func create() throws(IO.Event.Error) -> IO.Event.Driver.Handle {
        let kq = Darwin.kqueue()
        guard kq >= 0 else {
            throw IO.Event.Error.platform(errno: errno)
        }

        // Initialize empty registry for this kqueue
        registry.withLock { $0[kq] = [:] }

        return IO.Event.Driver.Handle(rawValue: kq)
    }

    /// Registers a file descriptor with the kqueue.
    static func register(
        _ handle: borrowing IO.Event.Driver.Handle,
        descriptor: Int32,
        interest: IO.Event.Interest
    ) throws(IO.Event.Error) -> IO.Event.ID {
        let kq = handle.rawValue
        let id = IO.Event.ID(raw: nextID.wrappingAdd(1, ordering: .relaxed).newValue)

        // Prepare kevent structures for registration
        var events: [Darwin.kevent] = []

        if interest.contains(.read) {
            var ev = Darwin.kevent()
            ev.ident = UInt(descriptor)
            ev.filter = Int16(EVFILT_READ)
            // EV_ADD: Add filter (starts enabled)
            // EV_CLEAR: Edge-triggered
            // EV_DISPATCH: Auto-disable after delivery (requires re-arm)
            //
            // We start ENABLED so events that occur before arm() are captured
            // as permits. If we started disabled, edges would be lost.
            ev.flags = UInt16(EV_ADD | EV_CLEAR | EV_DISPATCH)
            ev.fflags = 0
            ev.data = 0
            ev.udata = UnsafeMutableRawPointer(bitPattern: UInt(id.raw))
            events.append(ev)
        }

        if interest.contains(.write) {
            var ev = Darwin.kevent()
            ev.ident = UInt(descriptor)
            ev.filter = Int16(EVFILT_WRITE)
            // EV_ADD: Add filter (starts enabled)
            // EV_CLEAR: Edge-triggered
            // EV_DISPATCH: Auto-disable after delivery (requires re-arm)
            //
            // We start ENABLED so events that occur before arm() are captured
            // as permits. If we started disabled, edges would be lost.
            ev.flags = UInt16(EV_ADD | EV_CLEAR | EV_DISPATCH)
            ev.fflags = 0
            ev.data = 0
            ev.udata = UnsafeMutableRawPointer(bitPattern: UInt(id.raw))
            events.append(ev)
        }

        guard !events.isEmpty else {
            // Still store the mapping even with no interests
            registry.withLock { registrations in
                registrations[kq]?[id] = RegistrationEntry(descriptor: descriptor, interest: interest)
            }
            return id
        }

        let result = events.withUnsafeBufferPointer { ptr in
            kevent_c(kq, ptr.baseAddress, Int32(ptr.count), nil, 0, nil)
        }
        if result < 0 {
            throw IO.Event.Error.platform(errno: errno)
        }

        // Store the mapping for future modify/deregister
        registry.withLock { registrations in
            registrations[kq]?[id] = RegistrationEntry(descriptor: descriptor, interest: interest)
        }

        return id
    }

    /// Modifies the interests for a registration.
    static func modify(
        _ handle: borrowing IO.Event.Driver.Handle,
        id: IO.Event.ID,
        interest newInterest: IO.Event.Interest
    ) throws(IO.Event.Error) {
        let kq = handle.rawValue

        // Look up the registration
        let entry: RegistrationEntry? = registry.withLock { $0[kq]?[id] }
        guard let entry else {
            throw IO.Event.Error.notRegistered
        }

        let descriptor = entry.descriptor
        let oldInterest = entry.interest

        // Calculate delta: what to add vs remove
        let toAdd = newInterest.subtracting(oldInterest)
        let toRemove = oldInterest.subtracting(newInterest)

        var events: [Darwin.kevent] = []

        // Remove old interests
        if toRemove.contains(.read) {
            var ev = Darwin.kevent()
            ev.ident = UInt(descriptor)
            ev.filter = Int16(EVFILT_READ)
            ev.flags = UInt16(EV_DELETE)
            ev.fflags = 0
            ev.data = 0
            ev.udata = UnsafeMutableRawPointer(bitPattern: UInt(id.raw))
            events.append(ev)
        }
        if toRemove.contains(.write) {
            var ev = Darwin.kevent()
            ev.ident = UInt(descriptor)
            ev.filter = Int16(EVFILT_WRITE)
            ev.flags = UInt16(EV_DELETE)
            ev.fflags = 0
            ev.data = 0
            ev.udata = UnsafeMutableRawPointer(bitPattern: UInt(id.raw))
            events.append(ev)
        }

        // Add new interests with EV_DISPATCH for one-shot semantics
        if toAdd.contains(.read) {
            var ev = Darwin.kevent()
            ev.ident = UInt(descriptor)
            ev.filter = Int16(EVFILT_READ)
            ev.flags = UInt16(EV_ADD | EV_CLEAR | EV_DISPATCH)
            ev.fflags = 0
            ev.data = 0
            ev.udata = UnsafeMutableRawPointer(bitPattern: UInt(id.raw))
            events.append(ev)
        }
        if toAdd.contains(.write) {
            var ev = Darwin.kevent()
            ev.ident = UInt(descriptor)
            ev.filter = Int16(EVFILT_WRITE)
            ev.flags = UInt16(EV_ADD | EV_CLEAR | EV_DISPATCH)
            ev.fflags = 0
            ev.data = 0
            ev.udata = UnsafeMutableRawPointer(bitPattern: UInt(id.raw))
            events.append(ev)
        }

        if !events.isEmpty {
            let result = events.withUnsafeBufferPointer { ptr in
                kevent_c(kq, ptr.baseAddress, Int32(ptr.count), nil, 0, nil)
            }
            if result < 0 {
                throw IO.Event.Error.platform(errno: errno)
            }
        }

        // Update stored interest
        registry.withLock { registrations in
            registrations[kq]?[id]?.interest = newInterest
        }
    }

    /// Deregisters a file descriptor.
    ///
    /// Removes all event filters for the registration and cleans up the mapping.
    /// Idempotent: returns successfully if already deregistered.
    static func deregister(
        _ handle: borrowing IO.Event.Driver.Handle,
        id: IO.Event.ID
    ) throws(IO.Event.Error) {
        let kq = handle.rawValue

        // Remove from registry and get the entry atomically
        let entry: RegistrationEntry? = registry.withLock { registrations in
            registrations[kq]?.removeValue(forKey: id)
        }

        // Idempotent: if not registered, succeed silently
        guard let entry else {
            return
        }

        let descriptor = entry.descriptor
        let interest = entry.interest

        // Delete all registered filters
        var events: [Darwin.kevent] = []

        if interest.contains(.read) {
            var ev = Darwin.kevent()
            ev.ident = UInt(descriptor)
            ev.filter = Int16(EVFILT_READ)
            ev.flags = UInt16(EV_DELETE)
            ev.fflags = 0
            ev.data = 0
            ev.udata = UnsafeMutableRawPointer(bitPattern: UInt(id.raw))
            events.append(ev)
        }
        if interest.contains(.write) {
            var ev = Darwin.kevent()
            ev.ident = UInt(descriptor)
            ev.filter = Int16(EVFILT_WRITE)
            ev.flags = UInt16(EV_DELETE)
            ev.fflags = 0
            ev.data = 0
            ev.udata = UnsafeMutableRawPointer(bitPattern: UInt(id.raw))
            events.append(ev)
        }

        if !events.isEmpty {
            let result = events.withUnsafeBufferPointer { ptr in
                kevent_c(kq, ptr.baseAddress, Int32(ptr.count), nil, 0, nil)
            }
            // Ignore ENOENT - the event may have been auto-removed if fd was closed
            if result < 0 && errno != ENOENT {
                throw IO.Event.Error.platform(errno: errno)
            }
        }
    }

    /// Arms a registration for readiness notification.
    ///
    /// Enables the kernel filter for the specified interest. With EV_DISPATCH,
    /// the filter is automatically disabled after delivering an event, requiring
    /// a subsequent arm() call to re-enable.
    ///
    /// This implements the "arm → event → arm" lifecycle that aligns with the
    /// selector's token typestate and edge-triggered semantics.
    static func arm(
        _ handle: borrowing IO.Event.Driver.Handle,
        id: IO.Event.ID,
        interest: IO.Event.Interest
    ) throws(IO.Event.Error) {
        let kq = handle.rawValue

        // Look up the registration
        let entry: RegistrationEntry? = registry.withLock { $0[kq]?[id] }
        guard let entry else {
            throw IO.Event.Error.notRegistered
        }

        let descriptor = entry.descriptor
        var events: [Darwin.kevent] = []

        if interest.contains(.read) {
            var ev = Darwin.kevent()
            ev.ident = UInt(descriptor)
            ev.filter = Int16(EVFILT_READ)
            // EV_ADD: Required to modify filter parameters (not just enable/disable)
            // EV_ENABLE: Re-enable the filter after EV_DISPATCH disabled it
            // EV_CLEAR: Edge-triggered - reset state after delivery
            // EV_DISPATCH: Auto-disable after delivery (one-shot arming)
            ev.flags = UInt16(EV_ADD | EV_ENABLE | EV_CLEAR | EV_DISPATCH)
            ev.fflags = 0
            ev.data = 0
            ev.udata = UnsafeMutableRawPointer(bitPattern: UInt(id.raw))
            events.append(ev)
        }

        if interest.contains(.write) {
            var ev = Darwin.kevent()
            ev.ident = UInt(descriptor)
            ev.filter = Int16(EVFILT_WRITE)
            // EV_ADD: Required to modify filter parameters (not just enable/disable)
            // EV_ENABLE: Re-enable the filter after EV_DISPATCH disabled it
            // EV_CLEAR: Edge-triggered - reset state after delivery
            // EV_DISPATCH: Auto-disable after delivery (one-shot arming)
            ev.flags = UInt16(EV_ADD | EV_ENABLE | EV_CLEAR | EV_DISPATCH)
            ev.fflags = 0
            ev.data = 0
            ev.udata = UnsafeMutableRawPointer(bitPattern: UInt(id.raw))
            events.append(ev)
        }

        guard !events.isEmpty else { return }

        let result = events.withUnsafeBufferPointer { ptr in
            kevent_c(kq, ptr.baseAddress, Int32(ptr.count), nil, 0, nil)
        }
        if result < 0 {
            throw IO.Event.Error.platform(errno: errno)
        }
    }

    /// Polls for events.
    static func poll(
        _ handle: borrowing IO.Event.Driver.Handle,
        deadline: IO.Event.Deadline?,
        into buffer: inout [IO.Event]
    ) throws(IO.Event.Error) -> Int {
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
            throw IO.Event.Error.platform(errno: err)
        }

        // Get current registrations for filtering stale events
        let kq = handle.rawValue
        let registeredIDs: Set<IO.Event.ID> = registry.withLock { registrations in
            if let ids = registrations[kq]?.keys {
                return Set(ids)
            }
            return []
        }

        // Convert raw events to IO.Event
        var outputIndex = 0
        for i in 0..<Int(count) {
            let raw = rawEvents[i]

            // Skip user events (wakeup)
            if raw.filter == Int16(EVFILT_USER) {
                continue
            }

            let id = IO.Event.ID(raw: UInt64(UInt(bitPattern: raw.udata)))

            // Poll race rule: drop events for deregistered IDs
            guard registeredIDs.contains(id) else {
                continue
            }

            var interest: IO.Event.Interest = []
            if raw.filter == Int16(EVFILT_READ) {
                interest.insert(.read)
            }
            if raw.filter == Int16(EVFILT_WRITE) {
                interest.insert(.write)
            }

            var flags: IO.Event.Flags = []
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

            buffer[outputIndex] = IO.Event(id: id, interest: interest, flags: flags)
            outputIndex += 1
        }

        return outputIndex
    }

    /// Closes the kqueue handle.
    ///
    /// Cleans up the registry and closes the kqueue file descriptor.
    /// All registered events are automatically removed by the kernel when the fd closes.
    static func close(_ handle: consuming IO.Event.Driver.Handle) {
        let kq = handle.rawValue

        // Clean up the registry
        _ = registry.withLock { $0.removeValue(forKey: kq) }

        Darwin.close(kq)
    }

    /// Creates a wakeup channel using EVFILT_USER.
    static func createWakeupChannel(
        _ handle: borrowing IO.Event.Driver.Handle
    ) throws(IO.Event.Error) -> IO.Event.Wakeup.Channel {
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
            throw IO.Event.Error.platform(errno: errno)
        }

        // Capture the kqueue fd for the wakeup channel
        let kq = handle.rawValue

        return IO.Event.Wakeup.Channel {
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
