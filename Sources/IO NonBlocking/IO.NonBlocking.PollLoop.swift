//
//  IO.NonBlocking.PollLoop.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 28/12/2025.
//

import Synchronization

extension IO.NonBlocking {
    /// Poll loop running on a dedicated OS thread.
    ///
    /// The poll loop is the heart of the non-blocking I/O system. It:
    /// 1. Blocks in `driver.poll()` waiting for kernel events
    /// 2. Processes registration requests from the selector
    /// 3. Pushes events to the selector via `Event.Bridge`
    ///
    /// ## Thread Safety
    /// The poll loop owns the driver handle for its entire lifetime.
    /// All driver operations happen on this thread.
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
        ///   - registrationQueue: Queue for receiving requests from selector.
        ///   - shutdownFlag: Atomic flag indicating shutdown.
        public static func run(
            driver: Driver,
            handle: consuming Driver.Handle,
            eventBridge: Event.Bridge,
            registrationQueue: Registration.Queue,
            shutdownFlag: Shutdown.Flag
        ) {
            var eventBuffer = [Event](
                repeating: .empty,
                count: driver.capabilities.maxEvents
            )

            while !shutdownFlag.isSet {
                // Process any pending registration requests
                processRequests(
                    driver: driver,
                    handle: handle,
                    queue: registrationQueue
                )

                // Block waiting for kernel events
                do {
                    let count = try driver.poll(
                        handle,
                        deadline: nil,
                        into: &eventBuffer
                    )

                    if count > 0 {
                        // Copy events to a new array and push to bridge
                        let batch = Array(eventBuffer.prefix(count))
                        eventBridge.push(batch)
                    }
                } catch {
                    // Poll error - signal shutdown
                    eventBridge.shutdown()
                    break
                }
            }

            // Shutdown sequence
            handleShutdown(
                driver: driver,
                handle: handle,
                registrationQueue: registrationQueue
            )
        }

        /// Process pending registration requests.
        private static func processRequests(
            driver: Driver,
            handle: borrowing Driver.Handle,
            queue: Registration.Queue
        ) {
            while let request = queue.dequeue() {
                switch request {
                case .register(let descriptor, let interest, let continuation):
                    do {
                        let id = try driver.register(
                            handle,
                            descriptor: descriptor,
                            interest: interest
                        )
                        continuation.resume(returning: .success(id))
                    } catch {
                        continuation.resume(returning: .failure(error))
                    }

                case .modify(let id, let interest, let continuation):
                    do {
                        try driver.modify(handle, id: id, interest: interest)
                        continuation.resume(returning: .success(()))
                    } catch {
                        continuation.resume(returning: .failure(error))
                    }

                case .deregister(let id, let continuation):
                    do {
                        try driver.deregister(handle, id: id)
                        continuation?.resume(returning: .success(()))
                    } catch {
                        continuation?.resume(returning: .failure(error))
                    }
                }
            }
        }

        /// Handle shutdown sequence.
        private static func handleShutdown(
            driver: Driver,
            handle: consuming Driver.Handle,
            registrationQueue: Registration.Queue
        ) {
            // Process remaining deregistration requests
            for request in registrationQueue.dequeueAll() {
                switch request {
                case .deregister(let id, let continuation):
                    do {
                        try driver.deregister(handle, id: id)
                        continuation?.resume(returning: .success(()))
                    } catch {
                        continuation?.resume(returning: .failure(error))
                    }
                case .register(_, _, let continuation):
                    // Reject new registrations during shutdown
                    continuation.resume(returning: .failure(
                        IO.Lifecycle.Error<IO.NonBlocking.Error>.shutdownInProgress
                    ))
                case .modify(_, _, let continuation):
                    // Reject modifications during shutdown
                    continuation.resume(returning: .failure(
                        IO.Lifecycle.Error<IO.NonBlocking.Error>.shutdownInProgress
                    ))
                }
            }

            // Close driver handle (consumes it)
            driver.close(handle)
        }
    }
}

// MARK: - Context

extension IO.NonBlocking.PollLoop {
    /// Context passed to the poll thread during initialization.
    ///
    /// This struct bundles all the data needed by the poll thread.
    /// It is ~Copyable because it contains the driver handle.
    public struct Context: ~Copyable, Sendable {
        public let driver: IO.NonBlocking.Driver
        public var handle: IO.NonBlocking.Driver.Handle
        public let eventBridge: IO.NonBlocking.Event.Bridge
        public let registrationQueue: IO.NonBlocking.Registration.Queue
        public let shutdownFlag: IO.NonBlocking.PollLoop.Shutdown.Flag

        public init(
            driver: IO.NonBlocking.Driver,
            handle: consuming IO.NonBlocking.Driver.Handle,
            eventBridge: IO.NonBlocking.Event.Bridge,
            registrationQueue: IO.NonBlocking.Registration.Queue,
            shutdownFlag: IO.NonBlocking.PollLoop.Shutdown.Flag
        ) {
            self.driver = driver
            self.handle = handle
            self.eventBridge = eventBridge
            self.registrationQueue = registrationQueue
            self.shutdownFlag = shutdownFlag
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
            registrationQueue: context.registrationQueue,
            shutdownFlag: context.shutdownFlag
        )
    }
}
