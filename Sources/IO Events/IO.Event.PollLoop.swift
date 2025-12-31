//
//  IO.Event.PollLoop.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 28/12/2025.
//

import Synchronization

extension IO.Event {
    /// Poll loop running on a dedicated OS thread.
    ///
    /// The poll loop is the heart of the non-blocking I/O system. It:
    /// 1. Blocks in `driver.poll()` waiting for kernel events
    /// 2. Processes registration requests from the selector
    /// 3. Pushes events to the selector via `Event.Bridge`
    /// 4. Pushes registration replies via `Registration.Reply.Bridge`
    ///
    /// ## Thread Safety
    /// The poll loop owns the driver handle for its entire lifetime.
    /// All driver operations happen on this thread.
    ///
    /// ## Single Resumption Funnel
    /// The poll thread NEVER resumes selector-owned continuations directly.
    /// Instead, it pushes replies to `Registration.Reply.Bridge`, and the
    /// selector resumes continuations on its executor.
    ///
    /// ## Lifecycle
    /// 1. Started during `Selector.make()`
    /// 2. Runs until shutdown is signaled via `Wakeup.Channel`
    /// 3. Processes remaining deregistrations during shutdown
    /// 4. Closes the driver handle before exiting
    public enum PollLoop {
        /// Run the poll loop.
        ///
        /// This function does not return until shutdown is signaled.
        /// It consumes the driver handle.
        ///
        /// - Parameters:
        ///   - driver: The driver to use for polling.
        ///   - handle: The driver handle (consumed).
        ///   - eventBridge: Bridge for sending events to selector.
        ///   - replyBridge: Bridge for sending registration replies to selector.
        ///   - registrationQueue: Queue for receiving requests from selector.
        ///   - shutdownFlag: Atomic flag indicating shutdown.
        ///   - nextDeadline: Atomic deadline for poll timeout.
        public static func run(
            driver: Driver,
            handle: consuming Driver.Handle,
            eventBridge: IO.Event.Bridge,
            replyBridge: Registration.Reply.Bridge,
            registrationQueue: Registration.Queue,
            shutdownFlag: Shutdown.Flag,
            nextDeadline: NextDeadline
        ) {
            var eventBuffer = [IO.Event](
                repeating: .empty,
                count: driver.capabilities.maxEvents
            )

            while !shutdownFlag.isSet {
                // Process any pending registration requests
                processRequests(
                    driver: driver,
                    handle: handle,
                    queue: registrationQueue,
                    replyBridge: replyBridge
                )

                // Block waiting for kernel events (with optional timeout)
                do {
                    let deadline = nextDeadline.asDeadline
                    let count = try driver.poll(
                        handle,
                        deadline: deadline,
                        into: &eventBuffer
                    )

                    if count > 0 {
                        // Copy events to a new array and push to bridge
                        let batch = Array(eventBuffer.prefix(count))
                        eventBridge.push(batch)
                    } else {
                        // Timeout with no events - tick to wake selector for deadline drain
                        eventBridge.tick()
                    }
                } catch {
                    // Poll error - signal shutdown
                    eventBridge.shutdown()
                    replyBridge.shutdown()
                    break
                }
            }

            // Shutdown sequence
            handleShutdown(
                driver: driver,
                handle: handle,
                registrationQueue: registrationQueue,
                replyBridge: replyBridge
            )
        }

        /// Process pending registration requests.
        ///
        /// Pushes replies to `replyBridge` instead of resuming continuations directly.
        /// This ensures all continuations are resumed on the selector executor.
        private static func processRequests(
            driver: Driver,
            handle: borrowing Driver.Handle,
            queue: Registration.Queue,
            replyBridge: Registration.Reply.Bridge
        ) {
            while let request = queue.dequeue() {
                switch request {
                case .register(let descriptor, let interest, let replyID):
                    do {
                        let id = try driver.register(
                            handle,
                            descriptor: descriptor,
                            interest: interest
                        )
                        replyBridge.push(Registration.Reply(id: replyID, result: .success(.registered(id))))
                    } catch {
                        replyBridge.push(Registration.Reply(id: replyID, result: .failure(error)))
                    }

                case .modify(let id, let interest, let replyID):
                    do {
                        try driver.modify(handle, id: id, interest: interest)
                        replyBridge.push(Registration.Reply(id: replyID, result: .success(.modified)))
                    } catch {
                        replyBridge.push(Registration.Reply(id: replyID, result: .failure(error)))
                    }

                case .deregister(let id, let replyID):
                    do {
                        try driver.deregister(handle, id: id)
                        if let replyID {
                            replyBridge.push(Registration.Reply(id: replyID, result: .success(.deregistered)))
                        }
                    } catch {
                        if let replyID {
                            replyBridge.push(Registration.Reply(id: replyID, result: .failure(error)))
                        }
                    }

                case .arm(let id, let interest):
                    // Fire-and-forget: enable the kernel filter for this interest.
                    // Errors here indicate the registration is invalid (already deregistered),
                    // which means the waiter will be resumed via deregistration error path.
                    try? driver.arm(handle, id: id, interest: interest)
                }
            }
        }

        /// Handle shutdown sequence.
        private static func handleShutdown(
            driver: Driver,
            handle: consuming Driver.Handle,
            registrationQueue: Registration.Queue,
            replyBridge: Registration.Reply.Bridge
        ) {
            // Process remaining deregistration requests
            for request in registrationQueue.dequeueAll() {
                switch request {
                case .deregister(let id, let replyID):
                    do {
                        try driver.deregister(handle, id: id)
                        if let replyID {
                            replyBridge.push(Registration.Reply(id: replyID, result: .success(.deregistered)))
                        }
                    } catch {
                        if let replyID {
                            replyBridge.push(Registration.Reply(id: replyID, result: .failure(error)))
                        }
                    }
                case .register(_, _, let replyID):
                    // Reject new registrations during shutdown with a sentinel error.
                    // The selector wraps this in IO.Lifecycle.Error.shutdownInProgress.
                    replyBridge.push(Registration.Reply(id: replyID, result: .failure(.invalidDescriptor)))
                case .modify(_, _, let replyID):
                    // Reject modifications during shutdown with a sentinel error.
                    replyBridge.push(Registration.Reply(id: replyID, result: .failure(.notRegistered)))
                case .arm:
                    // Ignore arm requests during shutdown - waiter will be
                    // resumed with shutdownInProgress by selector.
                    break
                }
            }

            // Close driver handle (consumes it)
            driver.close(handle)
        }
    }
}

// MARK: - Context

extension IO.Event.PollLoop {
    /// Context passed to the poll thread during initialization.
    ///
    /// This struct bundles all the data needed by the poll thread.
    /// It is ~Copyable because it contains the driver handle.
    public struct Context: ~Copyable, Sendable {
        public let driver: IO.Event.Driver
        public var handle: IO.Event.Driver.Handle
        public let eventBridge: IO.Event.Bridge
        public let replyBridge: IO.Event.Registration.Reply.Bridge
        public let registrationQueue: IO.Event.Registration.Queue
        public let shutdownFlag: IO.Event.PollLoop.Shutdown.Flag
        public let nextDeadline: IO.Event.PollLoop.NextDeadline

        public init(
            driver: IO.Event.Driver,
            handle: consuming IO.Event.Driver.Handle,
            eventBridge: IO.Event.Bridge,
            replyBridge: IO.Event.Registration.Reply.Bridge,
            registrationQueue: IO.Event.Registration.Queue,
            shutdownFlag: IO.Event.PollLoop.Shutdown.Flag,
            nextDeadline: IO.Event.PollLoop.NextDeadline
        ) {
            self.driver = driver
            self.handle = handle
            self.eventBridge = eventBridge
            self.replyBridge = replyBridge
            self.registrationQueue = registrationQueue
            self.shutdownFlag = shutdownFlag
            self.nextDeadline = nextDeadline
        }
    }

    /// Run the poll loop with a context.
    ///
    /// - Parameter context: The poll thread context (consumed).
    public static func run(_ context: consuming Context) {
        run(
            driver: context.driver,
            handle: context.handle,
            eventBridge: context.eventBridge,
            replyBridge: context.replyBridge,
            registrationQueue: context.registrationQueue,
            shutdownFlag: context.shutdownFlag,
            nextDeadline: context.nextDeadline
        )
    }
}
