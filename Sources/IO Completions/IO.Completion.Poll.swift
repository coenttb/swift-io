//
//  IO.Completion.Poll.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 31/12/2025.
//

public import Dimension
public import Kernel
public import Runtime

extension IO.Completion {
    /// Namespace for poll loop types.
    public enum Poll {}
}

// MARK: - Run

extension IO.Completion.Poll {
    /// Runs the poll loop until shutdown.
    ///
    /// This is the main entry point for the poll thread. It:
    /// 1. Drains submissions from the queue
    /// 2. Submits them to the driver
    /// 3. Flushes pending submissions
    /// 4. Polls for completion events
    /// 5. Pushes events to the bridge
    /// 6. Repeats until shutdown flag is set
    /// 7. Closes the handle on exit
    ///
    /// ## Ownership
    ///
    /// Consumes the context, including the handle. The handle is closed
    /// on exit, ensuring proper resource cleanup.
    ///
    /// ## Error Handling
    ///
    /// Driver errors during the loop are logged but do not stop the loop.
    /// The loop only exits when the shutdown flag is set.
    ///
    /// - Parameter context: The poll loop context (consumed).
    public static func run(_ context: consuming Context) {
        // Extract resources from context
        let driver = context.driver
        var handle = context.handle
        let submissions = context.submissions
        let bridge = context.bridge
        let shutdownFlag = context.shutdownFlag

        // Pre-allocate buffers
        var submissionBuffer: [IO.Completion.Operation.Storage] = []
        submissionBuffer.reserveCapacity(driver.capabilities.maxSubmissions)

        var eventBuffer: [IO.Completion.Event] = []
        eventBuffer.reserveCapacity(driver.capabilities.maxCompletions)

        // Main loop
        while !shutdownFlag.rawValue.isSet {
            // 1. Drain submissions
            submissionBuffer.removeAll(keepingCapacity: true)
            _ = submissions.rawValue.dequeue.all(into: &submissionBuffer)

            // 2. Submit to driver
            for storage in submissionBuffer {
                do {
                    try driver.submit(handle, storage: storage)
                } catch {
                    // Log error but continue - individual submission failure
                    // shouldn't stop the loop
                }
            }

            // 3. Flush
            do {
                _ = try driver.flush(handle)
            } catch {
                // Log error but continue
            }

            // 4. Poll for events (blocking)
            eventBuffer.removeAll(keepingCapacity: true)
            do {
                let count = try driver.poll(
                    handle,
                    deadline: nil,  // Block indefinitely until events or wakeup
                    into: &eventBuffer
                )

                // 5. Push events to bridge
                if count > 0 {
                    bridge.rawValue.push(eventBuffer)
                }
            } catch {
                // Log error but continue - poll failures are often transient
                // (interrupted by signal, etc.)
            }
        }

        // 6. Shutdown: close handle
        driver.close(handle)
    }
}
