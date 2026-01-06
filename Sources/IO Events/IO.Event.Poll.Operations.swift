//
//  IO.Event.Poll.Operations.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 29/12/2025.
//

#if canImport(Glibc)

public import Kernel
import Synchronization

/// Module-level registry mapping epoll fd → (ID → registration).
///
/// Thread-safe via Mutex. Each epoll's entries are accessed only by its poll thread,
/// so contention is minimal (only during concurrent Selector creation/destruction).
private let registry = Mutex<[Int32: [IO.Event.ID: IO.Event.Registration.Entry]]>([:])

// MARK: - Operations

extension IO.Event.Poll {
    /// Internal implementation of epoll operations.
    enum Operations {
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
                descriptor = try Kernel.Event.Poll.create()
            } catch {
                throw IO.Event.Error(error)
            }
            
            let epfd = descriptor.rawValue
            
            // Initialize empty registry for this epoll
            IO.Event.Registry.shared.withLock { $0[epfd] = [:] }
            
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
            let event = Kernel.Event.Poll.Event(
                events: interestToKernelEvents(interest),
                data: UInt64(id.rawValue)
            )
            
            do {
                try Kernel.Event.Poll.ctl(
                    Kernel.Descriptor(rawValue: epfd),
                    op: .add,
                    fd: Kernel.Descriptor(rawValue: descriptor),
                    event: event
                )
            } catch {
                throw IO.Event.Error(error)
            }
            
            // Store the mapping for future modify/deregister
            IO.Event.Registry.shared.withLock { registrations in
                registrations[epfd]?[id] = IO.Event.Registration.Entry(descriptor: descriptor, interest: interest)
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
            let entry: IO.Event.Registration.Entry? = IO.Event.Registry.shared.withLock { $0[epfd]?[id] }
            guard let entry else {
                throw IO.Event.Error.notRegistered
            }
            
            let descriptor = entry.descriptor
            
            // Build new epoll_event with EPOLLONESHOT to preserve one-shot semantics
            let event = Kernel.Event.Poll.Event(
                events: interestToKernelEventsOneShot(newInterest),
                data: UInt64(id.rawValue)
            )
            
            do {
                try Kernel.Event.Poll.ctl(
                    Kernel.Descriptor(rawValue: epfd),
                    op: .modify,
                    fd: Kernel.Descriptor(rawValue: descriptor),
                    event: event
                )
            } catch {
                throw IO.Event.Error(error)
            }
            
            // Update stored interest
            IO.Event.Registry.shared.withLock { registrations in
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
            let entry: IO.Event.Registration.Entry? = IO.Event.Registry.shared.withLock { registrations in
                registrations[epfd]?.removeValue(forKey: id)
            }
            
            // Idempotent: if not registered, succeed silently
            guard let entry else {
                return
            }
            
            let descriptor = entry.descriptor
            
            // Remove from epoll
            do {
                try Kernel.Event.Poll.ctl(
                    Kernel.Descriptor(rawValue: epfd),
                    op: .delete,
                    fd: Kernel.Descriptor(rawValue: descriptor)
                )
            } catch let error as Kernel.Event.Poll.Error {
                // Ignore ENOENT - the fd may have been closed already
                if case .ctl(let errno) = error, errno == Kernel.Errno.noEntry {
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
            let entry: IO.Event.Registration.Entry? = IO.Event.Registry.shared.withLock { $0[epfd]?[id] }
            guard let entry else {
                throw IO.Event.Error.notRegistered
            }
            
            let descriptor = entry.descriptor
            
            // Build epoll_event with EPOLLONESHOT for one-shot arming
            let event = Kernel.Event.Poll.Event(
                events: interestToKernelEventsOneShot(interest),
                data: UInt64(id.rawValue)
            )
            
            // Use EPOLL_CTL_MOD to re-enable the descriptor
            do {
                try Kernel.Event.Poll.ctl(
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
                if now >= deadline.rawValue.nanoseconds {
                    timeoutMs = 0
                } else {
                    // Convert nanoseconds to milliseconds, clamping to Int32.max
                    let remaining = deadline.rawValue.nanoseconds - now
                    let ms = remaining / 1_000_000
                    timeoutMs = ms > UInt64(Int32.max) ? -1 : Int32(ms)
                }
            } else {
                timeoutMs = -1  // Block indefinitely
            }
            
            // Create buffer for Kernel.Event.Poll.Event
            var rawEvents = [Kernel.Event.Poll.Event](
                repeating: Kernel.Event.Poll.Event(events: Kernel.Event.Poll.Events(rawValue: 0), data: 0),
                count: buffer.count
            )
            
            let count: Int
            do {
                count = try Kernel.Event.Poll.wait(
                    Kernel.Descriptor(rawValue: epfd),
                    events: &rawEvents,
                    timeout: timeoutMs
                )
            } catch let error as Kernel.Event.Poll.Error {
                // Handle EINTR specially - return 0 events instead of throwing
                if case .interrupted = error {
                    return 0
                }
                throw IO.Event.Error(error)
            } catch {
                throw IO.Event.Error.platform(errno: Kernel.Errno.invalid)
            }
            
            // Get current registrations for filtering stale events
            let registeredIDs: Set<IO.Event.ID> = IO.Event.Registry.shared.withLock { registrations in
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
                guard id.rawValue != 0, registeredIDs.contains(id) else {
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
            _ = IO.Event.Registry.shared.withLock { $0.removeValue(forKey: epfd) }
            
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
                eventDescriptor = try Kernel.Event.Descriptor.create(
                    initval: .zero,
                    flags: .cloexec | .nonblock
                )
            } catch {
                throw IO.Event.Error(error)
            }
            
            let efd = eventDescriptor.rawValue
            
            // Register eventfd with epoll using ID 0 (reserved for wakeup)
            let event = Kernel.Event.Poll.Event(
                events: .in | .et,
                data: 0  // ID 0 = wakeup sentinel
            )
            
            do {
                try Kernel.Event.Poll.ctl(
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
                Kernel.Event.Descriptor.signal(Kernel.Descriptor(rawValue: efd))
            }
        }
        
        // MARK: - Helpers
        
        /// Converts Interest to Kernel.Event.Poll.Events (edge-triggered).
        private static func interestToKernelEvents(_ interest: IO.Event.Interest) -> Kernel.Event.Poll.Events {
            var events: Kernel.Event.Poll.Events = .et  // Always edge-triggered
            
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
        
        /// Converts Interest to Kernel.Event.Poll.Events with EPOLLONESHOT for one-shot arming.
        private static func interestToKernelEventsOneShot(_ interest: IO.Event.Interest) -> Kernel.Event.Poll.Events {
            var events: Kernel.Event.Poll.Events = .et | .oneshot
            
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
        
        /// Converts Kernel.Event.Poll.Events to Interest and Flags.
        private static func kernelEventsToInterestAndFlags(
            _ events: Kernel.Event.Poll.Events
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
}
// MARK: - Error Conversion

extension IO.Event.Error {
    /// Creates an IO.Event.Error from a Kernel.Event.Poll.Error.
    @inlinable
    init(_ epollError: Kernel.Event.Poll.Error) {
        switch epollError {
        case .create(let errno):
            self = .platform(errno: errno)
        case .ctl(let errno):
            self = .platform(errno: errno)
        case .wait(let errno):
            self = .platform(errno: errno)
        case .interrupted:
            self = .platform(errno: Kernel.Errno.interrupted)
        }
    }
    
    /// Creates an IO.Event.Error from a Kernel.Event.Descriptor.Error.
    @inlinable
    init(_ eventfdError: Kernel.Event.Descriptor.Error) {
        switch eventfdError {
        case .create(let errno):
            self = .platform(errno: errno)
        case .read(let errno):
            self = .platform(errno: errno)
        case .write(let errno):
            self = .platform(errno: errno)
        case .wouldBlock:
            self = .platform(errno: Kernel.Errno.wouldBlock)
        }
    }
}
#endif
