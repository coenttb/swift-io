//
//  IO.Event.Epoll.Operations.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 29/12/2025.
//

#if canImport(Glibc)

    public import Kernel
    import Synchronization

    // MARK: - Registration Mapping

    /// Per-registration state tracking descriptor and current interests.
    private struct RegistrationEntry: Sendable {
        let descriptor: Int32
        var interest: IO.Event.Interest
    }

    /// Module-level registry mapping epoll fd → (ID → registration).
    ///
    /// Thread-safe via Mutex. Each epoll's entries are accessed only by its poll thread,
    /// so contention is minimal (only during concurrent Selector creation/destruction).
    private let registry = Mutex<[Int32: [IO.Event.ID: RegistrationEntry]]>([:])

    // MARK: - Error Conversion

    extension IO.Event.Error {
        /// Creates an IO.Event.Error from a Kernel.Epoll.Error.
        @inlinable
        init(_ epollError: Kernel.Epoll.Error) {
            switch epollError {
            case .createFailed(let errno):
                self = .platform(errno: errno)
            case .ctlFailed(let errno):
                self = .platform(errno: errno)
            case .waitFailed(let errno):
                self = .platform(errno: errno)
            case .interrupted:
                self = .platform(errno: Kernel.Errno.interrupted)
            }
        }

        /// Creates an IO.Event.Error from a Kernel.Eventfd.Error.
        @inlinable
        init(_ eventfdError: Kernel.Eventfd.Error) {
            switch eventfdError {
            case .createFailed(let errno):
                self = .platform(errno: errno)
            case .readFailed(let errno):
                self = .platform(errno: errno)
            case .writeFailed(let errno):
                self = .platform(errno: errno)
            case .wouldBlock:
                self = .platform(errno: Kernel.Errno.wouldBlock)
            }
        }
    }

    /// Internal implementation of epoll operations.
    enum EpollOperations {
        /// Counter for generating unique registration IDs.
        ///
        /// ## Global State (PATTERN REQUIREMENTS §6.6)
        /// This is an intentional process-global atomic counter. Rationale:
        /// - Each registration needs a unique ID across all epoll instances
        /// - Atomic increment is lock-free and thread-safe
        /// - Wrapping at UInt64.max is acceptable (would require ~600 years at 1M/sec)
        private static let nextID = Atomic<UInt64>(0)

        /// Creates a new epoll handle.
        static func create() throws(IO.Event.Error) -> IO.Event.Driver.Handle {
            let descriptor: Kernel.Descriptor
            do {
                descriptor = try Kernel.Epoll.create()
            } catch {
                throw IO.Event.Error(error)
            }

            let epfd = descriptor.rawValue

            // Initialize empty registry for this epoll
            registry.withLock { $0[epfd] = [:] }

            return IO.Event.Driver.Handle(rawValue: epfd)
        }

        /// Registers a file descriptor with epoll.
        static func register(
            _ handle: borrowing IO.Event.Driver.Handle,
            descriptor: Int32,
            interest: IO.Event.Interest
        ) throws(IO.Event.Error) -> IO.Event.ID {
            let epfd = handle.rawValue
            let id = IO.Event.ID(UInt(truncatingIfNeeded: nextID.wrappingAdd(1, ordering: .relaxed).newValue))

            // Build epoll_event
            let event = Kernel.Epoll.Event(
                events: interestToKernelEvents(interest),
                data: UInt64(id._rawValue)
            )

            do {
                try Kernel.Epoll.ctl(
                    Kernel.Descriptor(rawValue: epfd),
                    op: .add,
                    fd: Kernel.Descriptor(rawValue: descriptor),
                    event: event
                )
            } catch {
                throw IO.Event.Error(error)
            }

            // Store the mapping for future modify/deregister
            registry.withLock { registrations in
                registrations[epfd]?[id] = RegistrationEntry(descriptor: descriptor, interest: interest)
            }

            return id
        }

        /// Modifies the interests for a registration.
        static func modify(
            _ handle: borrowing IO.Event.Driver.Handle,
            id: IO.Event.ID,
            interest newInterest: IO.Event.Interest
        ) throws(IO.Event.Error) {
            let epfd = handle.rawValue

            // Look up the registration
            let entry: RegistrationEntry? = registry.withLock { $0[epfd]?[id] }
            guard let entry else {
                throw IO.Event.Error.notRegistered
            }

            let descriptor = entry.descriptor

            // Build new epoll_event with EPOLLONESHOT to preserve one-shot semantics
            let event = Kernel.Epoll.Event(
                events: interestToKernelEventsOneShot(newInterest),
                data: UInt64(id._rawValue)
            )

            do {
                try Kernel.Epoll.ctl(
                    Kernel.Descriptor(rawValue: epfd),
                    op: .modify,
                    fd: Kernel.Descriptor(rawValue: descriptor),
                    event: event
                )
            } catch {
                throw IO.Event.Error(error)
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
            _ handle: borrowing IO.Event.Driver.Handle,
            id: IO.Event.ID
        ) throws(IO.Event.Error) {
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

            // Remove from epoll
            do {
                try Kernel.Epoll.ctl(
                    Kernel.Descriptor(rawValue: epfd),
                    op: .delete,
                    fd: Kernel.Descriptor(rawValue: descriptor)
                )
            } catch let error as Kernel.Epoll.Error {
                // Ignore ENOENT - the fd may have been closed already
                if case .ctlFailed(let errno) = error, errno == Kernel.Errno.noEntry {
                    // Ignore
                } else {
                    throw IO.Event.Error(error)
                }
            } catch {
                // Should never happen
                throw IO.Event.Error.platform(errno: Kernel.Errno.invalid)
            }
        }

        /// Arms a registration for readiness notification.
        ///
        /// Enables the descriptor for the specified interest using EPOLLONESHOT.
        /// After an event is delivered, the descriptor is automatically disabled
        /// and requires another arm() call to receive more events.
        ///
        /// This implements the "arm → event → arm" lifecycle that aligns with the
        /// selector's token typestate and edge-triggered semantics.
        static func arm(
            _ handle: borrowing IO.Event.Driver.Handle,
            id: IO.Event.ID,
            interest: IO.Event.Interest
        ) throws(IO.Event.Error) {
            let epfd = handle.rawValue

            // Look up the registration
            let entry: RegistrationEntry? = registry.withLock { $0[epfd]?[id] }
            guard let entry else {
                throw IO.Event.Error.notRegistered
            }

            let descriptor = entry.descriptor

            // Build epoll_event with EPOLLONESHOT for one-shot arming
            let event = Kernel.Epoll.Event(
                events: interestToKernelEventsOneShot(interest),
                data: UInt64(id._rawValue)
            )

            // Use EPOLL_CTL_MOD to re-enable the descriptor
            do {
                try Kernel.Epoll.ctl(
                    Kernel.Descriptor(rawValue: epfd),
                    op: .modify,
                    fd: Kernel.Descriptor(rawValue: descriptor),
                    event: event
                )
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
            let epfd = handle.rawValue

            // Calculate timeout in milliseconds
            let timeoutMs: Int32
            if let deadline = deadline {
                let now = Kernel.Time.monotonicNanoseconds()
                if now >= deadline.nanoseconds {
                    timeoutMs = 0
                } else {
                    // Convert nanoseconds to milliseconds, clamping to Int32.max
                    let remaining = deadline.nanoseconds - now
                    let ms = remaining / 1_000_000
                    timeoutMs = ms > UInt64(Int32.max) ? -1 : Int32(ms)
                }
            } else {
                timeoutMs = -1  // Block indefinitely
            }

            // Create buffer for Kernel.Epoll.Event
            var rawEvents = [Kernel.Epoll.Event](
                repeating: Kernel.Epoll.Event(events: Kernel.Epoll.Events(rawValue: 0), data: 0),
                count: buffer.count
            )

            let count: Int
            do {
                count = try Kernel.Epoll.wait(
                    Kernel.Descriptor(rawValue: epfd),
                    events: &rawEvents,
                    timeout: timeoutMs
                )
            } catch let error as Kernel.Epoll.Error {
                // Handle EINTR specially - return 0 events instead of throwing
                if case .interrupted = error {
                    return 0
                }
                throw IO.Event.Error(error)
            } catch {
                throw IO.Event.Error.platform(errno: Kernel.Errno.invalid)
            }

            // Get current registrations for filtering stale events
            let registeredIDs: Set<IO.Event.ID> = registry.withLock { registrations in
                if let ids = registrations[epfd]?.keys {
                    return Set(ids)
                }
                return []
            }

            // Convert raw events to IO.Event
            var outputIndex = 0
            for i in 0..<count {
                let raw = rawEvents[i]
                let id = IO.Event.ID(UInt(truncatingIfNeeded: raw.data))

                // Poll race rule: drop events for deregistered IDs
                // Also skip wakeup events (ID 0 is reserved for wakeup)
                guard id._rawValue != 0, registeredIDs.contains(id) else {
                    continue
                }

                let (interest, flags) = kernelEventsToInterestAndFlags(raw.events)

                buffer[outputIndex] = IO.Event(id: id, interest: interest, flags: flags)
                outputIndex += 1
            }

            return outputIndex
        }

        /// Closes the epoll handle.
        ///
        /// Cleans up the registry and closes the epoll file descriptor.
        static func close(_ handle: consuming IO.Event.Driver.Handle) {
            let epfd = handle.rawValue

            // Clean up the registry
            _ = registry.withLock { $0.removeValue(forKey: epfd) }

            // Use Kernel.Close, ignoring any errors (fire-and-forget)
            try? Kernel.Close.close(Kernel.Descriptor(rawValue: epfd))
        }

        /// Creates a wakeup channel using eventfd.
        static func createWakeupChannel(
            _ handle: borrowing IO.Event.Driver.Handle
        ) throws(IO.Event.Error) -> IO.Event.Wakeup.Channel {
            let epfd = handle.rawValue

            // Create eventfd for wakeup signaling
            let eventDescriptor: Kernel.Descriptor
            do {
                eventDescriptor = try Kernel.Eventfd.create(
                    initval: 0,
                    flags: .cloexec | .nonblock
                )
            } catch {
                throw IO.Event.Error(error)
            }

            let efd = eventDescriptor.rawValue

            // Register eventfd with epoll using ID 0 (reserved for wakeup)
            let event = Kernel.Epoll.Event(
                events: .in | .et,
                data: 0  // ID 0 = wakeup sentinel
            )

            do {
                try Kernel.Epoll.ctl(
                    Kernel.Descriptor(rawValue: epfd),
                    op: .add,
                    fd: eventDescriptor,
                    event: event
                )
            } catch {
                try? Kernel.Close.close(eventDescriptor)
                throw IO.Event.Error(error)
            }

            return IO.Event.Wakeup.Channel { [efd] in
                // Signal eventfd to trigger wakeup (fire-and-forget)
                Kernel.Eventfd.signal(Kernel.Descriptor(rawValue: efd))
            }
        }

        // MARK: - Helpers

        /// Converts Interest to Kernel.Epoll.Events (edge-triggered).
        private static func interestToKernelEvents(_ interest: IO.Event.Interest) -> Kernel.Epoll.Events {
            var events: Kernel.Epoll.Events = .et  // Always edge-triggered

            if interest.contains(.read) {
                events = events | .in
            }
            if interest.contains(.write) {
                events = events | .out
            }
            if interest.contains(.priority) {
                events = events | .pri
            }

            return events
        }

        /// Converts Interest to Kernel.Epoll.Events with EPOLLONESHOT for one-shot arming.
        private static func interestToKernelEventsOneShot(_ interest: IO.Event.Interest) -> Kernel.Epoll.Events {
            var events: Kernel.Epoll.Events = .et | .oneshot

            if interest.contains(.read) {
                events = events | .in
            }
            if interest.contains(.write) {
                events = events | .out
            }
            if interest.contains(.priority) {
                events = events | .pri
            }

            return events
        }

        /// Converts Kernel.Epoll.Events to Interest and Flags.
        private static func kernelEventsToInterestAndFlags(
            _ events: Kernel.Epoll.Events
        ) -> (IO.Event.Interest, IO.Event.Flags) {
            var interest: IO.Event.Interest = []
            var flags: IO.Event.Flags = []

            if events.contains(.in) {
                interest.insert(.read)
            }
            if events.contains(.out) {
                interest.insert(.write)
            }
            if events.contains(.pri) {
                interest.insert(.priority)
            }

            if events.contains(.err) {
                flags.insert(.error)
            }
            if events.contains(.hup) {
                flags.insert(.hangup)
            }
            if events.contains(.rdhup) {
                flags.insert(.readHangup)
            }

            return (interest, flags)
        }
    }

#endif
