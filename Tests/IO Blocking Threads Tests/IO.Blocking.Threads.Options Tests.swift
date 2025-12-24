//
//  IO.Blocking.Threads.Options Tests.swift
//  swift-io
//

import StandardsTestSupport
import Testing

@testable import IO_Blocking_Threads

extension IO.Blocking.Threads.Options {
    #TestSuites
}

// MARK: - Unit Tests

extension IO.Blocking.Threads.Options.Test.Unit {
    @Test("init with defaults")
    func initWithDefaults() {
        let options = IO.Blocking.Threads.Options()
        #expect(options.workers >= 1)
        #expect(options.queueLimit == 256)
        #expect(options.acceptanceWaitersLimit == 4 * 256)
        #expect(options.strategy == .wait)
    }

    @Test("init with custom workers")
    func initWithCustomWorkers() {
        let options = IO.Blocking.Threads.Options(workers: 4)
        #expect(options.workers == 4)
    }

    @Test("init with custom queueLimit")
    func initWithCustomQueueLimit() {
        let options = IO.Blocking.Threads.Options(queueLimit: 128)
        #expect(options.queueLimit == 128)
        #expect(options.acceptanceWaitersLimit == 4 * 128)
    }

    @Test("init with custom acceptanceWaitersLimit")
    func initWithCustomAcceptanceWaitersLimit() {
        let options = IO.Blocking.Threads.Options(
            queueLimit: 128,
            acceptanceWaitersLimit: 64
        )
        #expect(options.acceptanceWaitersLimit == 64)
    }

    @Test("init with throw backpressure")
    func initWithThrowBackpressure() {
        let options = IO.Blocking.Threads.Options(backpressure: .throw)
        #expect(options.strategy == .failFast)
    }

    @Test("Sendable conformance")
    func sendableConformance() async {
        let options = IO.Blocking.Threads.Options()
        await Task {
            #expect(options.queueLimit == 256)
        }.value
    }
}

// MARK: - Edge Cases

extension IO.Blocking.Threads.Options.Test.EdgeCase {
    @Test("workers minimum is 1")
    func workersMinimum() {
        let options = IO.Blocking.Threads.Options(workers: 0)
        #expect(options.workers >= 1)
    }

    @Test("queueLimit minimum is 1")
    func queueLimitMinimum() {
        let options = IO.Blocking.Threads.Options(queueLimit: 0)
        #expect(options.queueLimit >= 1)
    }

    @Test("acceptanceWaitersLimit minimum is 1")
    func acceptanceWaitersLimitMinimum() {
        let options = IO.Blocking.Threads.Options(acceptanceWaitersLimit: 0)
        #expect(options.acceptanceWaitersLimit >= 1)
    }

    @Test("negative workers clamped")
    func negativeWorkers() {
        let options = IO.Blocking.Threads.Options(workers: -5)
        #expect(options.workers >= 1)
    }
}
