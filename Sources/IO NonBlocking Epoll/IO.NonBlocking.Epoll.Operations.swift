//
//  IO.NonBlocking.Epoll.Operations.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 29/12/2025.
//

#if canImport(Glibc)

import Glibc
import Synchronization

// MARK: - Registration Mapping

/// Per-registration state tracking descriptor and current interests.
private struct RegistrationEntry: Sendable {
    let descriptor: Int32
    var interest: IO.NonBlocking.Interest
}

/// Module-level registry mapping epoll fd → (ID → registration).
///
/// Thread-safe via Mutex. Each epoll's entries are accessed only by its poll thread,
/// so contention is minimal (only during concurrent Selector creation/destruction).
private let registry = Mutex<[Int32: [IO.NonBlocking.ID: RegistrationEntry]]>([:])

/// Internal implementation of epoll operations.
enum EpollOperations {
    /// Counter for generating unique registration IDs.
    private static let nextID = Atomic<UInt64>(0)

    /// Creates a new epoll handle.
    static func create() throws(IO.NonBlocking.Error) -> IO.NonBlocking.Driver.Handle {
        let epfd = epoll_create1(EPOLL_CLOEXEC)
        guard epfd >= 0 else {
            throw IO.NonBlocking.Error.platform(errno: errno)
        }

        // Initialize empty registry for this epoll
        registry.withLock { $0[epfd] = [:] }

        return IO.NonBlocking.Driver.Handle(rawValue: epfd)
    }

    /// Registers a file descriptor with epoll.
    static func register(
        _ handle: borrowing IO.NonBlocking.Driver.Handle,
        descriptor: Int32,
        interest: IO.NonBlocking.Interest
    ) throws(IO.NonBlocking.Error) -> IO.NonBlocking.ID {
        let epfd = handle.rawValue
        let id = IO.NonBlocking.ID(raw: nextID.wrappingAdd(1, ordering: .relaxed).newValue)

        // Build epoll_event
        var event = epoll_event()
        event.events = interestToEpollEvents(interest)
        event.data.u64 = id.raw

        let result = epoll_ctl(epfd, EPOLL_CTL_ADD, descriptor, &event)
        if result < 0 {
            throw IO.NonBlocking.Error.platform(errno: errno)
        }

        // Store the mapping for future modify/deregister
        registry.withLock { registrations in
            registrations[epfd]?[id] = RegistrationEntry(descriptor: descriptor, interest: interest)
        }

        return id
    }

    /// Modifies the interests for a registration.
    static func modify(
        _ handle: borrowing IO.NonBlocking.Driver.Handle,
        id: IO.NonBlocking.ID,
        interest newInterest: IO.NonBlocking.Interest
    ) throws(IO.NonBlocking.Error) {
        let epfd = handle.rawValue

        // Look up the registration
        let entry: RegistrationEntry? = registry.withLock { $0[epfd]?[id] }
        guard let entry else {
            throw IO.NonBlocking.Error.notRegistered
        }

        let descriptor = entry.descriptor

        // Build new epoll_event
        var event = epoll_event()
        event.events = interestToEpollEvents(newInterest)
        event.data.u64 = id.raw

        let result = epoll_ctl(epfd, EPOLL_CTL_MOD, descriptor, &event)
        if result < 0 {
            throw IO.NonBlocking.Error.platform(errno: errno)
        }

        // Update stored interest
        registry.withLock { registrations in
            registrations[epfd]?[id]?.interest = newInterest
        }
    }

    /// Deregisters a file descriptor.
    ///
    /// Removes the descriptor from epoll and cleans up the mapping.
    /// Idempotent: returns successfully if already deregistered.
    static func deregister(
        _ handle: borrowing IO.NonBlocking.Driver.Handle,
        id: IO.NonBlocking.ID
    ) throws(IO.NonBlocking.Error) {
        let epfd = handle.rawValue

        // Remove from registry and get the entry atomically
        let entry: RegistrationEntry? = registry.withLock { registrations in
            registrations[epfd]?.removeValue(forKey: id)
        }

        // Idempotent: if not registered, succeed silently
        guard let entry else {
            return
        }

        let descriptor = entry.descriptor

        // Remove from epoll - event parameter is ignored for EPOLL_CTL_DEL but required
        var event = epoll_event()
        let result = epoll_ctl(epfd, EPOLL_CTL_DEL, descriptor, &event)
        // Ignore ENOENT - the fd may have been closed already
        if result < 0 && errno != ENOENT {
            throw IO.NonBlocking.Error.platform(errno: errno)
        }
    }

    /// Polls for events.
    static func poll(
        _ handle: borrowing IO.NonBlocking.Driver.Handle,
        deadline: IO.NonBlocking.Deadline?,
        into buffer: inout [IO.NonBlocking.Event]
    ) throws(IO.NonBlocking.Error) -> Int {
        let epfd = handle.rawValue

        // Calculate timeout in milliseconds
        let timeoutMs: Int32
        if let deadline = deadline {
            let now = getMonotonicTime()
            let deadlineNanos = Int64(bitPattern: deadline.nanoseconds)
            let remaining = deadlineNanos - now
            if remaining <= 0 {
                timeoutMs = 0
            } else {
                // Convert nanoseconds to milliseconds, clamping to Int32.max
                let ms = remaining / 1_000_000
                timeoutMs = ms > Int64(Int32.max) ? -1 : Int32(ms)
            }
        } else {
            timeoutMs = -1  // Block indefinitely
        }

        // Create buffer for raw epoll_event structures
        var rawEvents = [epoll_event](repeating: epoll_event(), count: buffer.count)

        let count = rawEvents.withUnsafeMutableBufferPointer { ptr in
            epoll_wait(epfd, ptr.baseAddress, Int32(ptr.count), timeoutMs)
        }

        if count < 0 {
            let err = errno
            if err == EINTR {
                return 0  // Interrupted, return 0 events
            }
            throw IO.NonBlocking.Error.platform(errno: err)
        }

        // Get current registrations for filtering stale events
        let registeredIDs: Set<IO.NonBlocking.ID> = registry.withLock { registrations in
            if let ids = registrations[epfd]?.keys {
                return Set(ids)
            }
            return []
        }

        // Convert raw events to IO.NonBlocking.Event
        var outputIndex = 0
        for i in 0..<Int(count) {
            let raw = rawEvents[i]
            let id = IO.NonBlocking.ID(raw: raw.data.u64)

            // Poll race rule: drop events for deregistered IDs
            // Also skip wakeup events (ID 0 is reserved for wakeup)
            guard id.raw != 0, registeredIDs.contains(id) else {
                continue
            }

            let (interest, flags) = epollEventsToInterestAndFlags(raw.events)

            buffer[outputIndex] = IO.NonBlocking.Event(id: id, interest: interest, flags: flags)
            outputIndex += 1
        }

        return outputIndex
    }

    /// Closes the epoll handle.
    ///
    /// Cleans up the registry and closes the epoll file descriptor.
    static func close(_ handle: consuming IO.NonBlocking.Driver.Handle) {
        let epfd = handle.rawValue

        // Clean up the registry
        _ = registry.withLock { $0.removeValue(forKey: epfd) }

        Glibc.close(epfd)
    }

    /// Creates a wakeup channel using eventfd.
    static func createWakeupChannel(
        _ handle: borrowing IO.NonBlocking.Driver.Handle
    ) throws(IO.NonBlocking.Error) -> IO.NonBlocking.Wakeup.Channel {
        let epfd = handle.rawValue

        // Create eventfd for wakeup signaling
        let efd = eventfd(0, EFD_CLOEXEC | EFD_NONBLOCK)
        guard efd >= 0 else {
            throw IO.NonBlocking.Error.platform(errno: errno)
        }

        // Register eventfd with epoll using ID 0 (reserved for wakeup)
        var event = epoll_event()
        event.events = UInt32(EPOLLIN) | UInt32(EPOLLET)
        event.data.u64 = 0  // ID 0 = wakeup sentinel

        let result = epoll_ctl(epfd, EPOLL_CTL_ADD, efd, &event)
        if result < 0 {
            let err = errno
            Glibc.close(efd)
            throw IO.NonBlocking.Error.platform(errno: err)
        }

        return IO.NonBlocking.Wakeup.Channel { [efd] in
            // Write to eventfd to trigger wakeup
            var val: UInt64 = 1
            _ = withUnsafePointer(to: &val) { ptr in
                write(efd, ptr, MemoryLayout<UInt64>.size)
            }
        }
    }

    // MARK: - Helpers

    /// Converts Interest to epoll event flags.
    private static func interestToEpollEvents(_ interest: IO.NonBlocking.Interest) -> UInt32 {
        var events: UInt32 = UInt32(EPOLLET)  // Always edge-triggered

        if interest.contains(.read) {
            events |= UInt32(EPOLLIN)
        }
        if interest.contains(.write) {
            events |= UInt32(EPOLLOUT)
        }
        if interest.contains(.priority) {
            events |= UInt32(EPOLLPRI)
        }

        return events
    }

    /// Converts epoll event flags to Interest and Flags.
    private static func epollEventsToInterestAndFlags(
        _ events: UInt32
    ) -> (IO.NonBlocking.Interest, IO.NonBlocking.Event.Flags) {
        var interest: IO.NonBlocking.Interest = []
        var flags: IO.NonBlocking.Event.Flags = []

        if events & UInt32(EPOLLIN) != 0 {
            interest.insert(.read)
        }
        if events & UInt32(EPOLLOUT) != 0 {
            interest.insert(.write)
        }
        if events & UInt32(EPOLLPRI) != 0 {
            interest.insert(.priority)
        }

        if events & UInt32(EPOLLERR) != 0 {
            flags.insert(.error)
        }
        if events & UInt32(EPOLLHUP) != 0 {
            flags.insert(.hangup)
        }
        if events & UInt32(EPOLLRDHUP) != 0 {
            flags.insert(.readHangup)
        }

        return (interest, flags)
    }

    /// Gets the current monotonic time in nanoseconds.
    private static func getMonotonicTime() -> Int64 {
        var ts = timespec()
        clock_gettime(CLOCK_MONOTONIC, &ts)
        return Int64(ts.tv_sec) * 1_000_000_000 + Int64(ts.tv_nsec)
    }
}

#endif
