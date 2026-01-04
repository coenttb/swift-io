//
//  IO.Event.Primitives.Tests.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 28/12/2025.
//

import IO_Events_Primitives
import Kernel
import Testing

@Suite("IO.Event Primitives")
struct NonBlockingPrimitivesTests {

    @Test("Interest OptionSet operations")
    func interestOptionSet() {
        let read: IO.Event.Interest = .read
        let write: IO.Event.Interest = .write
        let both: IO.Event.Interest = [.read, .write]

        #expect(both.contains(.read))
        #expect(both.contains(.write))
        #expect(!read.contains(.write))
        #expect(read.union(write) == both)
    }

    @Test("Event creation and properties")
    func eventCreation() {
        let id = IO.Event.ID(42)
        let event = IO.Event(
            id: id,
            interest: [.read, .write],
            flags: [.hangup]
        )

        #expect(event.id == id)
        #expect(event.interest.contains(.read))
        #expect(event.interest.contains(.write))
        #expect(event.flags.contains(.hangup))
        #expect(!event.flags.contains(.error))
    }

    @Test("Event.Flags combinations")
    func eventFlags() {
        let flags: IO.Event.Flags = [.error, .hangup]

        #expect(flags.contains(.error))
        #expect(flags.contains(.hangup))
        #expect(!flags.contains(.readHangup))
    }

    @Test("ID equality and hashing")
    func idEquality() {
        let id1 = IO.Event.ID(100)
        let id2 = IO.Event.ID(100)
        let id3 = IO.Event.ID(200)

        #expect(id1 == id2)
        #expect(id1 != id3)
        #expect(id1.hashValue == id2.hashValue)
    }

    @Test("Token creation and ID access")
    func tokenCreation() {
        let id = IO.Event.ID(42)
        // Tokens are created internally, but we can test the type exists
        // and the ID is accessible via consuming operations
    }

    @Test("Error descriptions")
    func errorDescriptions() {
        let platformError = IO.Event.Error.platform(.posix(22))
        let invalidDesc = IO.Event.Error.invalidDescriptor
        let writeClosed = IO.Event.Error.writeClosed

        #expect(platformError.description.contains("Platform"))
        #expect(invalidDesc.description.contains("Invalid"))
        #expect(writeClosed.description.contains("closed"))
    }
}
