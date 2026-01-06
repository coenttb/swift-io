//
//  IO.Event.Poll.Loop.Context.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 28/12/2025.
//

extension IO.Event.Poll.Loop {
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
        public let shutdownFlag: IO.Event.Poll.Loop.Shutdown.Flag
        public let nextDeadline: IO.Event.Poll.Loop.Deadline.Next

        public init(
            driver: IO.Event.Driver,
            handle: consuming IO.Event.Driver.Handle,
            eventBridge: IO.Event.Bridge,
            replyBridge: IO.Event.Registration.Reply.Bridge,
            registrationQueue: IO.Event.Registration.Queue,
            shutdownFlag: IO.Event.Poll.Loop.Shutdown.Flag,
            nextDeadline: IO.Event.Poll.Loop.Deadline.Next
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
}

// MARK: - Run with Context

extension IO.Event.Poll.Loop {
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
