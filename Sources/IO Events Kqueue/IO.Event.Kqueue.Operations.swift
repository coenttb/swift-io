//
//  IO.Event.Kqueue.Operations.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 28/12/2025.
//

#if canImport(Darwin)

    public import Kernel
    import SystemPackage
    import Synchronization

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

    // MARK: - Error Conversion

    extension IO.Event.Error {
        /// Creates an IO.Event.Error from a Kernel.Kqueue.Error.
        init(_ kqueueError: Kernel.Kqueue.Error) {
            switch kqueueError {
            case .create(let code):
                self = .platform(code)
            case .kevent(let code):
                self = .platform(code)
            case .interrupted:
                // Map interrupted to EINTR platform error
                self = .platform(.posix(Errno.interrupted.rawValue))
            }
        }
    }

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
            let descriptor: Kernel.Descriptor
            do {
                descriptor = try Kernel.Kqueue.create()
            } catch {
                throw IO.Event.Error(error)
            }

            let kq = descriptor.rawValue

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
            let id = IO.Event.ID(UInt(truncatingIfNeeded: nextID.wrappingAdd(1, ordering: .relaxed).newValue))

            // Prepare kevent structures for registration
            var events: [Kernel.Kqueue.Event] = []

            // EV_ADD: Add filter (starts enabled)
            // EV_CLEAR: Edge-triggered
            // EV_DISPATCH: Auto-disable after delivery (requires re-arm)
            //
            // We start ENABLED so events that occur before arm() are captured
            // as permits. If we started disabled, edges would be lost.
            let addFlags: Kernel.Kqueue.Flags = .add | .clear | .dispatch

            if interest.contains(.read) {
                events.append(Kernel.Kqueue.Event(
                    id: Kernel.Event.ID(UInt(descriptor)),
                    filter: .read,
                    flags: addFlags,
                    data: Kernel.Kqueue.Event.Data(UInt64(id._rawValue))
                ))
            }

            if interest.contains(.write) {
                events.append(Kernel.Kqueue.Event(
                    id: Kernel.Event.ID(UInt(descriptor)),
                    filter: .write,
                    flags: addFlags,
                    data: Kernel.Kqueue.Event.Data(UInt64(id._rawValue))
                ))
            }

            guard !events.isEmpty else {
                // Still store the mapping even with no interests
                registry.withLock { registrations in
                    registrations[kq]?[id] = RegistrationEntry(descriptor: descriptor, interest: interest)
                }
                return id
            }

            do {
                try Kernel.Kqueue.register(Kernel.Descriptor(rawValue: kq), events: events)
            } catch {
                throw IO.Event.Error(error)
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

            var events: [Kernel.Kqueue.Event] = []

            // Remove old interests
            if toRemove.contains(.read) {
                events.append(Kernel.Kqueue.Event(
                    id: Kernel.Event.ID(UInt(descriptor)),
                    filter: .read,
                    flags: .delete,
                    data: Kernel.Kqueue.Event.Data(UInt64(id._rawValue))
                ))
            }
            if toRemove.contains(.write) {
                events.append(Kernel.Kqueue.Event(
                    id: Kernel.Event.ID(UInt(descriptor)),
                    filter: .write,
                    flags: .delete,
                    data: Kernel.Kqueue.Event.Data(UInt64(id._rawValue))
                ))
            }

            // Add new interests with EV_DISPATCH for one-shot semantics
            let addFlags: Kernel.Kqueue.Flags = .add | .clear | .dispatch
            if toAdd.contains(.read) {
                events.append(Kernel.Kqueue.Event(
                    id: Kernel.Event.ID(UInt(descriptor)),
                    filter: .read,
                    flags: addFlags,
                    data: Kernel.Kqueue.Event.Data(UInt64(id._rawValue))
                ))
            }
            if toAdd.contains(.write) {
                events.append(Kernel.Kqueue.Event(
                    id: Kernel.Event.ID(UInt(descriptor)),
                    filter: .write,
                    flags: addFlags,
                    data: Kernel.Kqueue.Event.Data(UInt64(id._rawValue))
                ))
            }

            if !events.isEmpty {
                do {
                    try Kernel.Kqueue.register(Kernel.Descriptor(rawValue: kq), events: events)
                } catch {
                    throw IO.Event.Error(error)
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
            var events: [Kernel.Kqueue.Event] = []

            if interest.contains(.read) {
                events.append(Kernel.Kqueue.Event(
                    id: Kernel.Event.ID(UInt(descriptor)),
                    filter: .read,
                    flags: .delete,
                    data: Kernel.Kqueue.Event.Data(UInt64(id._rawValue))
                ))
            }
            if interest.contains(.write) {
                events.append(Kernel.Kqueue.Event(
                    id: Kernel.Event.ID(UInt(descriptor)),
                    filter: .write,
                    flags: .delete,
                    data: Kernel.Kqueue.Event.Data(UInt64(id._rawValue))
                ))
            }

            if !events.isEmpty {
                do {
                    try Kernel.Kqueue.register(Kernel.Descriptor(rawValue: kq), events: events)
                } catch {
                    // Ignore ENOENT - the event may have been auto-removed if fd was closed
                    if case .kevent(let code) = error, code.posix == Errno.noSuchFileOrDirectory.rawValue {
                        // Ignore
                    } else {
                        throw IO.Event.Error(error)
                    }
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
            var events: [Kernel.Kqueue.Event] = []

            // EV_ADD: Required to modify filter parameters (not just enable/disable)
            // EV_ENABLE: Re-enable the filter after EV_DISPATCH disabled it
            // EV_CLEAR: Edge-triggered - reset state after delivery
            // EV_DISPATCH: Auto-disable after delivery (one-shot arming)
            let armFlags: Kernel.Kqueue.Flags = .add | .enable | .clear | .dispatch

            if interest.contains(.read) {
                events.append(Kernel.Kqueue.Event(
                    id: Kernel.Event.ID(UInt(descriptor)),
                    filter: .read,
                    flags: armFlags,
                    data: Kernel.Kqueue.Event.Data(UInt64(id._rawValue))
                ))
            }

            if interest.contains(.write) {
                events.append(Kernel.Kqueue.Event(
                    id: Kernel.Event.ID(UInt(descriptor)),
                    filter: .write,
                    flags: armFlags,
                    data: Kernel.Kqueue.Event.Data(UInt64(id._rawValue))
                ))
            }

            guard !events.isEmpty else { return }

            do {
                try Kernel.Kqueue.register(Kernel.Descriptor(rawValue: kq), events: events)
            } catch {
                throw IO.Event.Error(error)
            }
        }

        /// Polls for events.
        static func poll(
            _ handle: borrowing IO.Event.Driver.Handle,
            deadline: IO.Event.Deadline?,
            into buffer: inout [IO.Event]
        ) throws(IO.Event.Error) -> Int {
            // Calculate Duration from deadline
            var duration: Duration? = nil
            if let deadline = deadline {
                let now = Kernel.Time.monotonicNanoseconds()
                let deadlineNanos = Int64(bitPattern: deadline.nanoseconds)
                let remaining = deadlineNanos - now
                if remaining <= 0 {
                    duration = .zero
                } else {
                    duration = .nanoseconds(remaining)
                }
            }

            // Create a buffer for raw kevent structures
            var rawEvents = [Kernel.Kqueue.Event](
                repeating: Kernel.Kqueue.Event(id: .zero, filter: .read, flags: .none),
                count: buffer.count
            )

            let count: Int
            do {
                count = try Kernel.Kqueue.poll(
                    Kernel.Descriptor(rawValue: handle.rawValue),
                    into: &rawEvents,
                    timeout: duration
                )
            } catch {
                // Handle EINTR specially - return 0 events instead of throwing
                if case .interrupted = error {
                    return 0
                }
                throw IO.Event.Error(error)
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
            for i in 0..<count {
                let raw = rawEvents[i]

                // Skip user events (wakeup)
                if raw.filter == .user {
                    continue
                }

                let id = IO.Event.ID(UInt(truncatingIfNeeded: raw.data._rawValue))

                // Poll race rule: drop events for deregistered IDs
                guard registeredIDs.contains(id) else {
                    continue
                }

                var interest: IO.Event.Interest = []
                if raw.filter == .read {
                    interest.insert(.read)
                }
                if raw.filter == .write {
                    interest.insert(.write)
                }

                var flags: IO.Event.Flags = []
                if raw.flags.contains(.eof) {
                    flags.insert(.hangup)
                    if raw.filter == .read {
                        flags.insert(.readHangup)
                    } else if raw.filter == .write {
                        flags.insert(.writeHangup)
                    }
                }
                if raw.flags.contains(.error) {
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

            // Use Kernel.Close, ignoring any errors (fire-and-forget)
            try? Kernel.Close.close(Kernel.Descriptor(rawValue: kq))
        }

        /// Creates a wakeup channel using EVFILT_USER.
        static func createWakeupChannel(
            _ handle: borrowing IO.Event.Driver.Handle
        ) throws(IO.Event.Error) -> IO.Event.Wakeup.Channel {
            // Register a user event for wakeup
            let wakeupId = Kernel.Event.ID(1)  // Special id for wakeup

            let ev = Kernel.Kqueue.Event(
                id: wakeupId,
                filter: .user,
                flags: .add | .clear
            )

            do {
                try Kernel.Kqueue.register(
                    Kernel.Descriptor(rawValue: handle.rawValue),
                    events: [ev]
                )
            } catch {
                throw IO.Event.Error(error)
            }

            // Capture the kqueue fd for the wakeup channel
            let kq = handle.rawValue

            return IO.Event.Wakeup.Channel {
                // Trigger the user event
                let triggerEv = Kernel.Kqueue.Event(
                    id: wakeupId,
                    filter: .user,
                    flags: .none,
                    fflags: .trigger
                )

                // Fire-and-forget - ignore errors on wakeup
                _ = try? Kernel.Kqueue.register(
                    Kernel.Descriptor(rawValue: kq),
                    events: [triggerEv]
                )
            }
        }
    }

#endif
