//
//  IO.Completion.Driver.Fake.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 31/12/2025.
//

import Synchronization

@testable import IO_Completions

extension IO.Completion.Driver {
    /// Fake driver for deterministic testing.
    ///
    /// The fake driver records submissions and allows test code to inject
    /// completion events. It does not perform actual I/O.
    ///
    /// ## Usage
    ///
    /// ```swift
    /// let fake = IO.Completion.Driver.Fake()
    /// let driver = fake.driver()
    /// // Use driver in tests
    /// fake.complete(id: id, kind: .read, outcome: .success(.bytes(42)))
    /// ```
    ///
    /// ## Thread Safety
    ///
    /// `@unchecked Sendable` because it provides internal synchronization via `Mutex`.
    final class Fake: @unchecked Sendable {
        package let lock = Mutex<State>(State())

        struct State {
            /// Recorded submissions: ID -> Kind
            var submissions: [IO.Completion.ID: IO.Completion.Kind] = [:]

            /// Injectable completion events queue
            var completionQueue: [IO.Completion.Event] = []

            /// Whether wakeup was called
            var wakeupCalled: Bool = false
        }

        init() {}

        // MARK: - Test Helpers

        /// Records a submission (called by driver witness).
        func recordSubmission(id: IO.Completion.ID, kind: IO.Completion.Kind) {
            lock.withLock { state in
                state.submissions[id] = kind
            }
        }

        /// Injects a completion event for testing.
        ///
        /// - Parameters:
        ///   - id: The operation ID.
        ///   - kind: The operation kind.
        ///   - outcome: The completion outcome.
        func complete(
            id: IO.Completion.ID,
            kind: IO.Completion.Kind,
            outcome: IO.Completion.Outcome
        ) {
            let event = IO.Completion.Event(
                id: id,
                kind: kind,
                outcome: outcome
            )
            lock.withLock { state in
                state.completionQueue.append(event)
            }
        }

        /// Gets and clears pending completion events.
        func drainCompletions() -> [IO.Completion.Event] {
            lock.withLock { state in
                let events = state.completionQueue
                state.completionQueue = []
                return events
            }
        }

        /// Gets recorded submissions.
        var submissions: [IO.Completion.ID: IO.Completion.Kind] {
            lock.withLock { state in
                state.submissions
            }
        }

        /// Whether a wakeup was triggered.
        var wasWoken: Bool {
            lock.withLock { state in
                state.wakeupCalled
            }
        }

        /// Resets the wakeup flag.
        func resetWakeup() {
            lock.withLock { state in
                state.wakeupCalled = false
            }
        }

    }
}

// MARK: - Driver Init from Fake

extension IO.Completion.Driver {
    /// Creates a Driver configured to use a fake for testing.
    init(_ fake: Fake) {
        self.init(
                capabilities: IO.Completion.Driver.Capabilities(
                    maxSubmissions: 128,
                    maxCompletions: 128,
                    supportedKinds: .eventsAdapterV1,
                    batchedSubmission: false,
                    registeredBuffers: false,
                    multishot: false
                ),
                create: {
                    // Return a fake handle
                    #if os(Windows)
                    return IO.Completion.Driver.Handle(raw: UnsafeMutableRawPointer(bitPattern: 1)!)
                    #elseif os(Linux)
                    return IO.Completion.Driver.Handle(descriptor: -1, ringPtr: nil)
                    #else
                    return IO.Completion.Driver.Handle(descriptor: -1)
                    #endif
                },
                submit: { _, operation in
                    fake.recordSubmission(id: operation.id, kind: operation.kind)
                },
                flush: { _ in
                    0
                },
                poll: { _, _, buffer in
                    let events = fake.drainCompletions()
                    buffer.append(contentsOf: events)
                    return events.count
                },
                close: { _ in
                    // No-op
                },
                createWakeupChannel: { _ in
                    IO.Completion.Wakeup.Channel(
                        wake: {
                            fake.lock.withLock { state in
                                state.wakeupCalled = true
                            }
                        },
                        close: nil
                    )
                }
            )
    }
}
