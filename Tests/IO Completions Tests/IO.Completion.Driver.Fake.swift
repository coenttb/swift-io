//
//  IO.Completion.Driver.Fake.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 31/12/2025.
//

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif os(Windows)
import WinSDK
#endif

@testable import IO_Completions

extension IO.Completion.Driver {
    /// Fake driver for deterministic testing.
    ///
    /// The fake driver records submissions and allows test code to inject
    /// completion events. It provides blocking poll via POSIX condition variables.
    ///
    /// ## Usage
    ///
    /// ```swift
    /// let fake = IO.Completion.Driver.Fake()
    /// let driver = IO.Completion.Driver(fake)
    ///
    /// // In test - inject completion and wake poll
    /// fake.complete(id: id, kind: .read, outcome: .success(.bytes(42)))
    /// ```
    ///
    /// ## Thread Safety
    ///
    /// `@unchecked Sendable` because it provides internal synchronization via
    /// mutex + condition variable.
    final class Fake: @unchecked Sendable {
        // MARK: - State

        struct State {
            /// Recorded submissions: ID -> Kind
            var submissions: [IO.Completion.ID: IO.Completion.Kind] = [:]

            /// Injectable completion events queue
            var completionQueue: [IO.Completion.Event] = []

            /// Whether wakeup was called
            var wakeupCalled: Bool = false

            /// Whether the fake is shutdown
            var isShutdown: Bool = false
        }

        private var state: State = State()

        // MARK: - Synchronization

        #if os(Windows)
        private var srwlock: SRWLOCK = SRWLOCK()
        private var condvar: CONDITION_VARIABLE = CONDITION_VARIABLE()
        #else
        private var mutex: pthread_mutex_t = pthread_mutex_t()
        private var cond: pthread_cond_t = pthread_cond_t()
        #endif

        init() {
            #if os(Windows)
            InitializeSRWLock(&srwlock)
            InitializeConditionVariable(&condvar)
            #else
            var mutexAttr = pthread_mutexattr_t()
            pthread_mutexattr_init(&mutexAttr)
            pthread_mutex_init(&mutex, &mutexAttr)
            pthread_mutexattr_destroy(&mutexAttr)

            var condAttr = pthread_condattr_t()
            pthread_condattr_init(&condAttr)
            #if !os(macOS) && !os(iOS) && !os(tvOS) && !os(watchOS)
            pthread_condattr_setclock(&condAttr, CLOCK_MONOTONIC)
            #endif
            pthread_cond_init(&cond, &condAttr)
            pthread_condattr_destroy(&condAttr)
            #endif
        }

        deinit {
            #if !os(Windows)
            pthread_cond_destroy(&cond)
            pthread_mutex_destroy(&mutex)
            #endif
        }

        // MARK: - Lock Operations

        private func lock() {
            #if os(Windows)
            AcquireSRWLockExclusive(&srwlock)
            #else
            pthread_mutex_lock(&mutex)
            #endif
        }

        private func unlock() {
            #if os(Windows)
            ReleaseSRWLockExclusive(&srwlock)
            #else
            pthread_mutex_unlock(&mutex)
            #endif
        }

        private func withLock<T>(_ body: (inout State) -> T) -> T {
            lock()
            defer { unlock() }
            return body(&state)
        }

        private func wait() {
            #if os(Windows)
            _ = SleepConditionVariableSRW(&condvar, &srwlock, INFINITE, 0)
            #else
            pthread_cond_wait(&cond, &mutex)
            #endif
        }

        private func signal() {
            #if os(Windows)
            WakeConditionVariable(&condvar)
            #else
            pthread_cond_signal(&cond)
            #endif
        }

        private func broadcast() {
            #if os(Windows)
            WakeAllConditionVariable(&condvar)
            #else
            pthread_cond_broadcast(&cond)
            #endif
        }

        // MARK: - Test Helpers

        /// Records a submission (called by driver witness).
        func recordSubmission(id: IO.Completion.ID, kind: IO.Completion.Kind) {
            withLock { state in
                state.submissions[id] = kind
            }
        }

        /// Injects a completion event and wakes the poll thread.
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
            lock()
            state.completionQueue.append(event)
            broadcast()
            unlock()
        }

        /// Signals the poll thread to wake up (without injecting events).
        func signalWakeup() {
            lock()
            state.wakeupCalled = true
            broadcast()
            unlock()
        }

        /// Shuts down the fake, waking any blocked poll.
        func shutdown() {
            lock()
            state.isShutdown = true
            broadcast()
            unlock()
        }

        /// Blocking poll for completion events.
        ///
        /// Blocks until:
        /// - Events are available
        /// - Wakeup is signaled
        /// - Shutdown is called
        /// - Deadline expires (if provided)
        ///
        /// - Parameters:
        ///   - deadline: Optional deadline for timeout.
        ///   - buffer: Buffer to receive events.
        /// - Returns: Number of events received.
        func pollBlocking(
            deadline: IO.Completion.Deadline?,
            into buffer: inout [IO.Completion.Event]
        ) -> Int {
            lock()
            defer { unlock() }

            // Wait until we have events, wakeup, or shutdown
            while state.completionQueue.isEmpty && !state.wakeupCalled && !state.isShutdown {
                if let deadline = deadline, deadline.hasExpired {
                    break
                }
                wait()
            }

            // Clear wakeup flag
            state.wakeupCalled = false

            // Drain events
            let events = state.completionQueue
            state.completionQueue = []
            buffer.append(contentsOf: events)
            return events.count
        }

        /// Gets and clears pending completion events (non-blocking).
        func drainCompletions() -> [IO.Completion.Event] {
            withLock { state in
                let events = state.completionQueue
                state.completionQueue = []
                return events
            }
        }

        /// Gets recorded submissions.
        var submissions: [IO.Completion.ID: IO.Completion.Kind] {
            withLock { state in
                state.submissions
            }
        }

        /// Whether a wakeup was triggered.
        var wasWoken: Bool {
            withLock { state in
                state.wakeupCalled
            }
        }

        /// Resets the wakeup flag.
        func resetWakeup() {
            withLock { state in
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
                supportedKinds: .iocp,  // Use IOCP kinds for testing
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
            submitStorage: { _, storage in
                fake.recordSubmission(id: storage.id, kind: storage.kind)
            },
            flush: { _ in
                0
            },
            poll: { _, deadline, buffer in
                fake.pollBlocking(deadline: deadline, into: &buffer)
            },
            close: { _ in
                fake.shutdown()
            },
            createWakeupChannel: { _ in
                IO.Completion.Wakeup.Channel(
                    wake: {
                        fake.signalWakeup()
                    },
                    close: nil
                )
            }
        )
    }
}
