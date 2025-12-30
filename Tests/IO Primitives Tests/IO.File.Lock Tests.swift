//
//  IO.File.Lock Tests.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 30/12/2025.
//

import Testing
@testable import IO_Primitives

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

@Suite("IO.File.Lock")
struct IOFileLockTests {

    // MARK: - Mode Tests

    @Suite("Mode")
    struct ModeTests {

        @Test("shared and exclusive modes are distinct")
        func modesAreDistinct() {
            let shared = IO.File.Lock.Mode.shared
            let exclusive = IO.File.Lock.Mode.exclusive

            #expect(shared != exclusive)
            #expect(shared == .shared)
            #expect(exclusive == .exclusive)
        }

        @Test("mode is Sendable")
        func modeIsSendable() {
            let mode: IO.File.Lock.Mode = .shared
            Task.detached {
                _ = mode
            }
        }
    }

    // MARK: - Range Tests

    @Suite("Range")
    struct RangeTests {

        @Test("bytes range initialization")
        func bytesRangeInit() {
            let range = IO.File.Lock.Range(start: 100, end: 200)

            #expect(range.start == 100)
            #expect(range.length == 100)

            // Verify it's a .bytes case
            if case .bytes(let start, let end) = range {
                #expect(start == 100)
                #expect(end == 200)
            } else {
                Issue.record("Expected .bytes case")
            }
        }

        @Test("range from Swift.Range")
        func rangeFromSwiftRange() {
            let swiftRange: Swift.Range<UInt64> = 50..<150
            let range = IO.File.Lock.Range(swiftRange)

            #expect(range.start == 50)
            #expect(range.length == 100)

            if case .bytes(let start, let end) = range {
                #expect(start == 50)
                #expect(end == 150)
            } else {
                Issue.record("Expected .bytes case")
            }
        }

        @Test("wholeFile is a distinct case")
        func wholeFileRange() {
            let range = IO.File.Lock.Range.wholeFile

            #expect(range.start == 0)
            #expect(range.length == UInt64.max)

            // Verify it's the .wholeFile case, not .bytes
            if case .wholeFile = range {
                // Good - it's the proper enum case
            } else {
                Issue.record("Expected .wholeFile case")
            }
        }

        @Test("wholeFile is not equal to bytes with same values")
        func wholeFileNotEqualToBytes() {
            let wholeFile = IO.File.Lock.Range.wholeFile
            // This would be the "sentinel" approach - now correctly distinct
            let bytesRange = IO.File.Lock.Range.bytes(start: 0, end: UInt64.max)

            #expect(wholeFile != bytesRange, "wholeFile should be distinct from bytes with same numeric values")
        }

        @Test("zero-length range")
        func zeroLengthRange() {
            let range = IO.File.Lock.Range(start: 100, end: 100)

            #expect(range.length == 0)
        }
    }

    // MARK: - Error Tests

    @Suite("Error")
    struct ErrorTests {

        @Test("error descriptions are meaningful")
        func errorDescriptions() {
            let errors: [IO.File.Lock.Error] = [
                .wouldBlock,
                .interrupted,
                .invalidRange,
                .notSupported,
                .permissionDenied,
                .invalidDescriptor,
                .deadlock,
                .timedOut,
                .platform(code: 42, message: "test error"),
            ]

            for error in errors {
                let description = error.description
                #expect(!description.isEmpty)
            }

            // Specific descriptions
            #expect(IO.File.Lock.Error.wouldBlock.description == "Lock would block")
            #expect(IO.File.Lock.Error.deadlock.description == "Deadlock detected")
        }

        @Test("error is Equatable")
        func errorEquatable() {
            #expect(IO.File.Lock.Error.wouldBlock == IO.File.Lock.Error.wouldBlock)
            #expect(IO.File.Lock.Error.wouldBlock != IO.File.Lock.Error.interrupted)

            let platform1 = IO.File.Lock.Error.platform(code: 1, message: "a")
            let platform2 = IO.File.Lock.Error.platform(code: 1, message: "a")
            let platform3 = IO.File.Lock.Error.platform(code: 2, message: "a")

            #expect(platform1 == platform2)
            #expect(platform1 != platform3)
        }
    }

    // MARK: - Token and Scoped Locking Tests

    #if !os(Windows)
    @Suite("Token")
    struct TokenTests {

        @Test("token acquires and releases lock on real file")
        func tokenAcquiresAndReleasesLock() throws {
            // Create a temporary file
            let path = "/tmp/swift-io-lock-test-\(getpid())"
            let fd = open(path, O_CREAT | O_RDWR, 0o644)
            defer {
                close(fd)
                unlink(path)
            }

            #expect(fd >= 0, "Failed to create test file")

            // Write some data
            let data = "test data"
            _ = data.withCString { ptr in
                #if canImport(Darwin)
                Darwin.write(fd, ptr, data.count)
                #elseif canImport(Glibc)
                Glibc.write(fd, ptr, data.count)
                #endif
            }

            // Acquire exclusive lock
            let token = try IO.File.Lock.Token(
                descriptor: fd,
                range: .wholeFile,
                mode: .exclusive,
                blocking: true
            )

            // Token should be valid (we can't really test much else without multi-process)
            // Just verify it doesn't crash

            // Release the lock
            token.release()
        }

        @Test("tryLock with non-blocking returns immediately")
        func tryLockNonBlocking() throws {
            let path = "/tmp/swift-io-trylock-test-\(getpid())"
            let fd = open(path, O_CREAT | O_RDWR, 0o644)
            defer {
                close(fd)
                unlink(path)
            }

            #expect(fd >= 0, "Failed to create test file")

            // Try to acquire lock without blocking
            let token = try IO.File.Lock.Token(
                descriptor: fd,
                range: .wholeFile,
                mode: .exclusive,
                blocking: false
            )

            // Should succeed since no one else has the lock
            token.release()
        }
    }

    @Suite("Scoped Locking")
    struct ScopedLockingTests {

        @Test("withExclusive holds lock during closure")
        func withExclusiveHoldsLock() throws {
            let path = "/tmp/swift-io-exclusive-test-\(getpid())"
            let fd = open(path, O_CREAT | O_RDWR, 0o644)
            defer {
                close(fd)
                unlink(path)
            }

            #expect(fd >= 0, "Failed to create test file")

            var wasInClosure = false

            let result = try IO.File.Lock.withExclusive(descriptor: fd) {
                wasInClosure = true
                return 42
            }

            #expect(wasInClosure)
            #expect(result == 42)
        }

        @Test("withShared holds lock during closure")
        func withSharedHoldsLock() throws {
            let path = "/tmp/swift-io-shared-test-\(getpid())"
            let fd = open(path, O_CREAT | O_RDWR, 0o644)
            defer {
                close(fd)
                unlink(path)
            }

            #expect(fd >= 0, "Failed to create test file")

            var wasInClosure = false

            let result = try IO.File.Lock.withShared(descriptor: fd) {
                wasInClosure = true
                return "hello"
            }

            #expect(wasInClosure)
            #expect(result == "hello")
        }

        @Test("scoped locking with byte range")
        func scopedLockingWithByteRange() throws {
            let path = "/tmp/swift-io-range-test-\(getpid())"
            let fd = open(path, O_CREAT | O_RDWR, 0o644)
            defer {
                close(fd)
                unlink(path)
            }

            #expect(fd >= 0, "Failed to create test file")

            // Write enough data
            let data = String(repeating: "x", count: 1024)
            _ = data.withCString { ptr in
                #if canImport(Darwin)
                Darwin.write(fd, ptr, data.count)
                #elseif canImport(Glibc)
                Glibc.write(fd, ptr, data.count)
                #endif
            }

            let range = IO.File.Lock.Range(start: 100, end: 200)

            var wasInClosure = false

            let result: Int = try IO.File.Lock.withExclusive(descriptor: fd, range: range) {
                wasInClosure = true
                return 123
            }

            #expect(wasInClosure)
            #expect(result == 123)
        }
    }
    #endif
}
