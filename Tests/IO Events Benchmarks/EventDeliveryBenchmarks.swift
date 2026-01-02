//
//  EventDeliveryBenchmarks.swift
//  swift-io
//
//  Benchmarks measuring event delivery latency through bridges.
//
//  ## What These Benchmarks Measure
//  - Event bridge throughput: poll thread → event bridge → consumer
//  - Reply bridge throughput: poll thread → reply bridge → consumer
//
//  ## Running
//  swift test -c release --filter EventDeliveryBenchmarks
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

enum EventDeliveryBenchmarks {
    #TestSuites
}

// MARK: - Bridge Throughput

extension EventDeliveryBenchmarks.Test.Performance {

    @Suite("Bridge Throughput")
    struct BridgeThroughput {

        @Test(
            "Event.Bridge push/next: 10000 ops",
            .timed(iterations: 3, warmup: 1, trackAllocations: false)
        )
        func eventBridgeThroughput() async {
            let bridge = IO.Event.Bridge()

            // Producer task
            let producerTask = Task {
                for i in 0..<10000 {
                    let event = IO.Event(
                        id: IO.Event.ID(raw: UInt64(i)),
                        interest: .read,
                        flags: []
                    )
                    bridge.push([event])
                }
                bridge.shutdown()
            }

            // Consumer
            var count = 0
            while let batch = await bridge.next() {
                count += batch.count
            }

            await producerTask.value
            withExtendedLifetime(count) {}
        }

        @Test(
            "Reply.Bridge push/next: 10000 ops",
            .timed(iterations: 3, warmup: 1, trackAllocations: false)
        )
        func replyBridgeThroughput() async {
            let bridge = IO.Event.Registration.Reply.Bridge()

            // Producer task
            let producerTask = Task {
                for i in 0..<10000 {
                    let reply = IO.Event.Registration.Reply(
                        id: IO.Event.Registration.ReplyID(raw: UInt64(i)),
                        result: .success(.registered(IO.Event.ID(raw: UInt64(i))))
                    )
                    bridge.push(reply)
                }
                bridge.shutdown()
            }

            // Consumer
            var count = 0
            while await bridge.next() != nil {
                count += 1
            }

            await producerTask.value
            withExtendedLifetime(count) {}
        }

        @Test(
            "Event.Bridge batched push/next: 1000 batches of 10",
            .timed(iterations: 3, warmup: 1, trackAllocations: false)
        )
        func eventBridgeBatchedThroughput() async {
            let bridge = IO.Event.Bridge()

            // Producer task - push in batches
            let producerTask = Task {
                for batchIndex in 0..<1000 {
                    var batch: [IO.Event] = []
                    for i in 0..<10 {
                        let event = IO.Event(
                            id: IO.Event.ID(raw: UInt64(batchIndex * 10 + i)),
                            interest: .read,
                            flags: []
                        )
                        batch.append(event)
                    }
                    bridge.push(batch)
                }
                bridge.shutdown()
            }

            // Consumer
            var count = 0
            while let batch = await bridge.next() {
                count += batch.count
            }

            await producerTask.value
            withExtendedLifetime(count) {}
        }
    }
}

// MARK: - Concurrent Bridge Access

extension EventDeliveryBenchmarks.Test.Performance {

    @Suite("Concurrent Bridge")
    struct ConcurrentBridge {

        @Test(
            "Event.Bridge: 4 producers, 1 consumer, 1000 events each",
            .timed(iterations: 3, warmup: 1, trackAllocations: false)
        )
        func concurrentProducers() async {
            let bridge = IO.Event.Bridge()
            let producerCount = 4
            let eventsPerProducer = 1000

            // Start producers
            await withTaskGroup(of: Void.self) { group in
                for producerIndex in 0..<producerCount {
                    group.addTask {
                        for i in 0..<eventsPerProducer {
                            let event = IO.Event(
                                id: IO.Event.ID(raw: UInt64(producerIndex * eventsPerProducer + i)),
                                interest: .read,
                                flags: []
                            )
                            bridge.push([event])
                        }
                    }
                }

                // Wait for all producers
                await group.waitForAll()
                bridge.shutdown()
            }

            // Consume any remaining
            var count = 0
            while let batch = await bridge.next() {
                count += batch.count
            }
            withExtendedLifetime(count) {}
        }
    }
}
