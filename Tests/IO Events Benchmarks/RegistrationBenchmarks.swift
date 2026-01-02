//
//  RegistrationBenchmarks.swift
//  swift-io
//
//  Benchmarks measuring registration throughput.
//
//  ## What These Benchmarks Measure
//  - Registration queue throughput
//  - Reply bridge round-trip overhead
//
//  ## Running
//  swift test -c release --filter RegistrationBenchmarks
//

import IO_Events_Kqueue
import StandardsTestSupport
import Testing

@testable import IO_Events

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

enum RegistrationBenchmarks {
    #TestSuites
}

// MARK: - Registration Queue Throughput

extension RegistrationBenchmarks.Test.Performance {

    @Suite("Registration Queue")
    struct Queue {

        @Test(
            "enqueue/dequeue: 10000 ops",
            .timed(iterations: 3, warmup: 1, trackAllocations: false)
        )
        func queueThroughput() async {
            let queue = IO.Event.Registration.Queue()

            // Enqueue
            for i in 0..<10000 {
                let request = IO.Event.Registration.Request.register(
                    descriptor: Int32(i),
                    interest: .read,
                    replyID: IO.Event.Registration.ReplyID(raw: UInt64(i))
                )
                queue.enqueue(request)
            }

            // Dequeue
            var count = 0
            while queue.dequeue() != nil {
                count += 1
            }
            withExtendedLifetime(count) {}
        }

        @Test(
            "concurrent enqueue: 4 threads, 1000 each",
            .timed(iterations: 3, warmup: 1, trackAllocations: false)
        )
        func concurrentEnqueue() async {
            let queue = IO.Event.Registration.Queue()
            let producerCount = 4
            let requestsPerProducer = 1000

            await withTaskGroup(of: Void.self) { group in
                for producerIndex in 0..<producerCount {
                    group.addTask {
                        for i in 0..<requestsPerProducer {
                            let request = IO.Event.Registration.Request.register(
                                descriptor: Int32(producerIndex * requestsPerProducer + i),
                                interest: .read,
                                replyID: IO.Event.Registration.ReplyID(raw: UInt64(i))
                            )
                            queue.enqueue(request)
                        }
                    }
                }
                await group.waitForAll()
            }

            // Dequeue all
            var count = 0
            while queue.dequeue() != nil {
                count += 1
            }
            withExtendedLifetime(count) {}
        }
    }
}

// MARK: - Wakeup Channel

extension RegistrationBenchmarks.Test.Performance {

    @Suite("Wakeup Channel")
    struct WakeupBenchmarks {

        @Test(
            "wake: 10000 ops",
            .timed(iterations: 3, warmup: 1, trackAllocations: false)
        )
        func wakeThroughput() async throws {
            let driver = IO.Event.Kqueue.driver()
            let handle = try driver.create()
            let wakeupChannel = try driver.createWakeupChannel(handle)

            for _ in 0..<10000 {
                wakeupChannel.wake()
            }

            driver.close(handle)
        }
    }
}
