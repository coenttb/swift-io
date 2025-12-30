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
#elseif os(Windows)
    import WinSDK
#endif

// Foundation only used for multi-process tests (Process, URL, Pipe)
#if canImport(Foundation)
    import Foundation
#endif

// MARK: - Cross-Platform Test Helpers

/// Returns a unique temporary file path for testing
func tempFilePath(prefix: String) -> String {
    #if os(Windows)
    var buffer = [WCHAR](repeating: 0, count: Int(MAX_PATH))
    GetTempPathW(DWORD(buffer.count), &buffer)
    let tempDir = String(decodingCString: buffer, as: UTF16.self)
    return "\(tempDir)\(prefix)-\(GetCurrentProcessId())-\(Int.random(in: 0..<Int.max))"
    #else
    return "/tmp/\(prefix)-\(getpid())-\(Int.random(in: 0..<Int.max))"
    #endif
}

#if !os(Windows)
/// Creates a temporary file and returns its path and file descriptor (POSIX)
func createTempFilePOSIX(prefix: String) -> (path: String, fd: Int32) {
    let path = tempFilePath(prefix: prefix)
    let fd = open(path, O_CREAT | O_RDWR, 0o644)
    return (path, fd)
}

/// Writes data to a file descriptor (POSIX)
func writeDataPOSIX(_ data: String, to fd: Int32) {
    _ = data.withCString { ptr in
        #if canImport(Darwin)
        Darwin.write(fd, ptr, data.count)
        #elseif canImport(Glibc)
        Glibc.write(fd, ptr, data.count)
        #endif
    }
}
#endif

#if os(Windows)
/// Creates a temporary file and returns its path and handle (Windows)
func createTempFileWindows(prefix: String) -> (path: String, handle: HANDLE) {
    let path = tempFilePath(prefix: prefix)
    let handle = path.withCString(encodedAs: UTF16.self) { widePath in
        CreateFileW(
            widePath,
            DWORD(GENERIC_READ | GENERIC_WRITE),
            0,
            nil,
            DWORD(CREATE_ALWAYS),
            DWORD(FILE_ATTRIBUTE_NORMAL),
            nil
        )
    }
    return (path, handle)
}

/// Deletes a file (Windows)
func deleteFileWindows(_ path: String) {
    path.withCString(encodedAs: UTF16.self) { widePath in
        DeleteFileW(widePath)
    }
}
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

    // MARK: - Token and Scoped Locking Tests (POSIX)

    #if !os(Windows)
    @Suite("Token")
    struct TokenTests {

        @Test("token acquires and releases lock on real file")
        func tokenAcquiresAndReleasesLock() throws {
            let (path, fd) = createTempFilePOSIX(prefix: "swift-io-lock-test")
            defer {
                close(fd)
                unlink(path)
            }

            #expect(fd >= 0, "Failed to create test file")
            writeDataPOSIX("test data", to: fd)

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
            let (path, fd) = createTempFilePOSIX(prefix: "swift-io-trylock-test")
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
    #endif

    // MARK: - Token Tests (Windows)

    #if os(Windows)
    @Suite("Token")
    struct TokenTests {

        @Test("token acquires and releases lock on real file")
        func tokenAcquiresAndReleasesLock() throws {
            let (path, handle) = createTempFileWindows(prefix: "swift-io-lock-test")
            defer {
                CloseHandle(handle)
                deleteFileWindows(path)
            }

            #expect(handle != INVALID_HANDLE_VALUE, "Failed to create test file")

            // Acquire exclusive lock
            let token = try IO.File.Lock.Token(
                handle: handle,
                range: .wholeFile,
                mode: .exclusive,
                blocking: true
            )

            // Release the lock
            token.release()
        }

        @Test("tryLock with non-blocking returns immediately")
        func tryLockNonBlocking() throws {
            let (path, handle) = createTempFileWindows(prefix: "swift-io-trylock-test")
            defer {
                CloseHandle(handle)
                deleteFileWindows(path)
            }

            #expect(handle != INVALID_HANDLE_VALUE, "Failed to create test file")

            // Try to acquire lock without blocking
            let token = try IO.File.Lock.Token(
                handle: handle,
                range: .wholeFile,
                mode: .exclusive,
                blocking: false
            )

            // Should succeed since no one else has the lock
            token.release()
        }
    }
    #endif

    // MARK: - Scoped Locking Tests (POSIX)

    #if !os(Windows)
    @Suite("Scoped Locking")
    struct ScopedLockingTests {

        @Test("withExclusive holds lock during closure")
        func withExclusiveHoldsLock() throws {
            let (path, fd) = createTempFilePOSIX(prefix: "swift-io-exclusive-test")
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
            let (path, fd) = createTempFilePOSIX(prefix: "swift-io-shared-test")
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
            let (path, fd) = createTempFilePOSIX(prefix: "swift-io-range-test")
            defer {
                close(fd)
                unlink(path)
            }

            #expect(fd >= 0, "Failed to create test file")

            // Write enough data
            writeDataPOSIX(String(repeating: "x", count: 1024), to: fd)

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

    // MARK: - Multi-Process Contention Tests

    #if canImport(Foundation) && !os(Windows)
    @Suite("Multi-Process Contention")
    struct MultiProcessContentionTests {

        /// Path to the lock test helper executable
        static var helperPath: String {
            // The helper is built alongside tests in .build/debug
            #if os(macOS)
            let buildDir = ".build/arm64-apple-macosx/debug"
            #elseif os(Linux)
            let buildDir = ".build/debug"
            #else
            let buildDir = ".build/debug"
            #endif
            return "\(buildDir)/_Lock Test Process"
        }

        /// Creates a temporary file for testing
        static func createTempFile() -> (path: String, fd: Int32) {
            let (path, fd) = createTempFilePOSIX(prefix: "swift-io-contention-test")
            // Write some data so the file isn't empty
            writeDataPOSIX(String(repeating: "x", count: 1024), to: fd)
            return (path, fd)
        }

        @Test("exclusive lock blocks try-exclusive from another process")
        func exclusiveBlocksTryExclusive() throws {
            let (path, fd) = Self.createTempFile()
            defer {
                close(fd)
                unlink(path)
            }

            #expect(fd >= 0, "Failed to create test file")

            // Acquire exclusive lock in this process
            let token = try IO.File.Lock.Token(
                descriptor: fd,
                range: .wholeFile,
                mode: .exclusive,
                blocking: true
            )

            // Spawn helper to try acquiring exclusive lock (should fail)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: Self.helperPath)
            process.arguments = ["try-exclusive", path, "--signal-ready"]

            let pipe = Pipe()
            process.standardOutput = pipe

            try process.run()
            process.waitUntilExit()

            let outputData = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: outputData, encoding: .utf8) ?? ""

            #expect(process.terminationStatus == 1, "Helper should exit with 1 (would block)")
            #expect(output.contains("WOULD_BLOCK"), "Helper should report WOULD_BLOCK")

            token.release()
        }

        @Test("exclusive lock blocks try-shared from another process")
        func exclusiveBlocksTryShared() throws {
            let (path, fd) = Self.createTempFile()
            defer {
                close(fd)
                unlink(path)
            }

            #expect(fd >= 0, "Failed to create test file")

            // Acquire exclusive lock in this process
            let token = try IO.File.Lock.Token(
                descriptor: fd,
                range: .wholeFile,
                mode: .exclusive,
                blocking: true
            )

            // Spawn helper to try acquiring shared lock (should fail)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: Self.helperPath)
            process.arguments = ["try-shared", path]

            let pipe = Pipe()
            process.standardOutput = pipe

            try process.run()
            process.waitUntilExit()

            let outputData = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: outputData, encoding: .utf8) ?? ""

            #expect(process.terminationStatus == 1, "Helper should exit with 1 (would block)")
            #expect(output.contains("WOULD_BLOCK"), "Helper should report WOULD_BLOCK")

            token.release()
        }

        @Test("shared lock allows try-shared from another process")
        func sharedAllowsTryShared() throws {
            let (path, fd) = Self.createTempFile()
            defer {
                close(fd)
                unlink(path)
            }

            #expect(fd >= 0, "Failed to create test file")

            // Acquire shared lock in this process
            let token = try IO.File.Lock.Token(
                descriptor: fd,
                range: .wholeFile,
                mode: .shared,
                blocking: true
            )

            // Spawn helper to try acquiring shared lock (should succeed)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: Self.helperPath)
            process.arguments = ["try-shared", path, "--hold", "0", "--signal-ready"]

            let pipe = Pipe()
            process.standardOutput = pipe

            try process.run()
            process.waitUntilExit()

            let outputData = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: outputData, encoding: .utf8) ?? ""

            #expect(process.terminationStatus == 0, "Helper should exit with 0 (success)")
            #expect(output.contains("READY"), "Helper should report READY")
            #expect(output.contains("RELEASED"), "Helper should report RELEASED")

            token.release()
        }

        @Test("shared lock blocks try-exclusive from another process")
        func sharedBlocksTryExclusive() throws {
            let (path, fd) = Self.createTempFile()
            defer {
                close(fd)
                unlink(path)
            }

            #expect(fd >= 0, "Failed to create test file")

            // Acquire shared lock in this process
            let token = try IO.File.Lock.Token(
                descriptor: fd,
                range: .wholeFile,
                mode: .shared,
                blocking: true
            )

            // Spawn helper to try acquiring exclusive lock (should fail)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: Self.helperPath)
            process.arguments = ["try-exclusive", path]

            let pipe = Pipe()
            process.standardOutput = pipe

            try process.run()
            process.waitUntilExit()

            let outputData = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: outputData, encoding: .utf8) ?? ""

            #expect(process.terminationStatus == 1, "Helper should exit with 1 (would block)")
            #expect(output.contains("WOULD_BLOCK"), "Helper should report WOULD_BLOCK")

            token.release()
        }

        @Test("non-overlapping byte ranges don't conflict")
        func nonOverlappingRangesDontConflict() throws {
            let (path, fd) = Self.createTempFile()
            defer {
                close(fd)
                unlink(path)
            }

            #expect(fd >= 0, "Failed to create test file")

            // Acquire exclusive lock on bytes 0-100 in this process
            let token = try IO.File.Lock.Token(
                descriptor: fd,
                range: .bytes(start: 0, end: 100),
                mode: .exclusive,
                blocking: true
            )

            // Spawn helper to try acquiring exclusive lock on bytes 200-300 (should succeed)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: Self.helperPath)
            process.arguments = ["try-exclusive", path, "--range", "200-300", "--hold", "0", "--signal-ready"]

            let pipe = Pipe()
            process.standardOutput = pipe

            try process.run()
            process.waitUntilExit()

            let outputData = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: outputData, encoding: .utf8) ?? ""

            #expect(process.terminationStatus == 0, "Helper should exit with 0 (success)")
            #expect(output.contains("READY"), "Helper should report READY")

            token.release()
        }

        @Test("overlapping byte ranges do conflict")
        func overlappingRangesConflict() throws {
            let (path, fd) = Self.createTempFile()
            defer {
                close(fd)
                unlink(path)
            }

            #expect(fd >= 0, "Failed to create test file")

            // Acquire exclusive lock on bytes 0-200 in this process
            let token = try IO.File.Lock.Token(
                descriptor: fd,
                range: .bytes(start: 0, end: 200),
                mode: .exclusive,
                blocking: true
            )

            // Spawn helper to try acquiring exclusive lock on bytes 100-300 (overlaps, should fail)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: Self.helperPath)
            process.arguments = ["try-exclusive", path, "--range", "100-300"]

            let pipe = Pipe()
            process.standardOutput = pipe

            try process.run()
            process.waitUntilExit()

            let outputData = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: outputData, encoding: .utf8) ?? ""

            #expect(process.terminationStatus == 1, "Helper should exit with 1 (would block)")
            #expect(output.contains("WOULD_BLOCK"), "Helper should report WOULD_BLOCK")

            token.release()
        }
    }
    #endif
}
