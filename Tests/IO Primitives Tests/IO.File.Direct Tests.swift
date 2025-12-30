//
//  IO.File.Direct Tests.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 30/12/2025.
//

import Testing
@testable import IO_Primitives
import Buffer
import Kernel
import Binary

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif os(Windows)
import WinSDK
#endif

// MARK: - Test Helpers

#if !os(Windows)
/// Creates a temporary file with content and returns its path
private func makeTempFile(prefix: String, content: String) -> String {
    let path = "/tmp/\(prefix)-\(getpid())-\(Int.random(in: 0..<Int.max))"
    let fd = open(path, O_CREAT | O_WRONLY, 0o644)
    guard fd >= 0 else { return path }
    defer { close(fd) }

    _ = content.withCString { ptr in
        write(fd, ptr, content.count)
    }

    return path
}

/// Creates a temporary file of specified size filled with a pattern
private func makeTempFileOfSize(prefix: String, size: Int, pattern: UInt8 = 0xAB) -> String {
    let path = "/tmp/\(prefix)-\(getpid())-\(Int.random(in: 0..<Int.max))"
    let fd = open(path, O_CREAT | O_WRONLY, 0o644)
    guard fd >= 0 else { return path }
    defer { close(fd) }

    let buffer = [UInt8](repeating: pattern, count: size)
    _ = buffer.withUnsafeBytes { ptr in
        write(fd, ptr.baseAddress!, size)
    }

    return path
}

/// Cleans up a temp file
private func removeTempFile(_ path: String) {
    _ = path.withCString { unlink($0) }
}
#endif

// MARK: - Mode Tests

@Suite("IO.File.Direct.Mode")
struct DirectModeTests {

    @Suite("Enum Values")
    struct EnumValueTests {

        @Test("mode cases exist and are distinct")
        func modeCasesExist() {
            let direct: IO.File.Direct.Mode = .direct
            let uncached: IO.File.Direct.Mode = .uncached
            let buffered: IO.File.Direct.Mode = .buffered
            let autoFallback: IO.File.Direct.Mode = .auto(policy: .fallbackToBuffered)
            let autoError: IO.File.Direct.Mode = .auto(policy: .errorOnViolation)

            #expect(direct != uncached)
            #expect(uncached != buffered)
            #expect(buffered != autoFallback)
            #expect(autoFallback != autoError)
        }

        @Test("resolved mode cases exist")
        func resolvedCasesExist() {
            let direct: IO.File.Direct.Mode.Resolved = .direct
            let uncached: IO.File.Direct.Mode.Resolved = .uncached
            let buffered: IO.File.Direct.Mode.Resolved = .buffered

            #expect(direct != uncached)
            #expect(uncached != buffered)
        }

        @Test("policy cases exist")
        func policyCasesExist() {
            let fallback: IO.File.Direct.Mode.Policy = .fallbackToBuffered
            let error: IO.File.Direct.Mode.Policy = .errorOnViolation

            #expect(fallback != error)
        }

        @Test("modes are Sendable")
        func modesAreSendable() {
            let mode: IO.File.Direct.Mode = .direct
            let resolved: IO.File.Direct.Mode.Resolved = .direct
            let policy: IO.File.Direct.Mode.Policy = .fallbackToBuffered

            Task.detached {
                _ = mode
                _ = resolved
                _ = policy
            }
        }
    }

    @Suite("Resolution")
    struct ResolutionTests {

        @Test(".buffered always resolves to .buffered")
        func bufferedResolvesAlways() throws {
            let mode: IO.File.Direct.Mode = .buffered

            // With known requirements
            let known = IO.File.Direct.Requirements(uniformAlignment: 4096)
            let result1 = try mode.resolve(given: known)
            #expect(result1 == .buffered)

            // With unknown requirements
            let unknown: IO.File.Direct.Requirements = .unknown(reason: .platformUnsupported)
            let result2 = try mode.resolve(given: unknown)
            #expect(result2 == .buffered)
        }

        #if os(macOS)
        @Test("macOS: .direct throws notSupported")
        func macOSDirectThrows() {
            let mode: IO.File.Direct.Mode = .direct
            let requirements: IO.File.Direct.Requirements = .unknown(reason: .platformUnsupported)

            #expect(throws: IO.File.Direct.Error.notSupported) {
                try mode.resolve(given: requirements)
            }
        }

        @Test("macOS: .uncached resolves to .uncached")
        func macOSUncachedResolves() throws {
            let mode: IO.File.Direct.Mode = .uncached
            let requirements: IO.File.Direct.Requirements = .unknown(reason: .platformUnsupported)

            let result = try mode.resolve(given: requirements)
            #expect(result == .uncached)
        }

        @Test("macOS: .auto resolves to .uncached")
        func macOSAutoResolvesToUncached() throws {
            let mode1: IO.File.Direct.Mode = .auto(policy: .fallbackToBuffered)
            let mode2: IO.File.Direct.Mode = .auto(policy: .errorOnViolation)
            let requirements: IO.File.Direct.Requirements = .unknown(reason: .platformUnsupported)

            let result1 = try mode1.resolve(given: requirements)
            let result2 = try mode2.resolve(given: requirements)

            #expect(result1 == .uncached)
            #expect(result2 == .uncached)
        }
        #endif

        #if os(Linux) || os(Windows)
        @Test("Linux/Windows: .direct with .known resolves to .direct")
        func directWithKnownResolves() throws {
            let mode: IO.File.Direct.Mode = .direct
            let requirements = IO.File.Direct.Requirements(uniformAlignment: 4096)

            let result = try mode.resolve(given: requirements)
            #expect(result == .direct)
        }

        @Test("Linux/Windows: .direct with .unknown throws")
        func directWithUnknownThrows() {
            let mode: IO.File.Direct.Mode = .direct
            let requirements: IO.File.Direct.Requirements = .unknown(reason: .sectorSizeUndetermined)

            #expect(throws: IO.File.Direct.Error.notSupported) {
                try mode.resolve(given: requirements)
            }
        }

        @Test("Linux/Windows: .uncached throws notSupported")
        func uncachedThrows() {
            let mode: IO.File.Direct.Mode = .uncached
            let requirements = IO.File.Direct.Requirements(uniformAlignment: 4096)

            #expect(throws: IO.File.Direct.Error.notSupported) {
                try mode.resolve(given: requirements)
            }
        }

        @Test("Linux/Windows: .auto(.fallbackToBuffered) with .unknown resolves to .buffered")
        func autoFallbackWithUnknown() throws {
            let mode: IO.File.Direct.Mode = .auto(policy: .fallbackToBuffered)
            let requirements: IO.File.Direct.Requirements = .unknown(reason: .sectorSizeUndetermined)

            let result = try mode.resolve(given: requirements)
            #expect(result == .buffered)
        }

        @Test("Linux/Windows: .auto(.fallbackToBuffered) with .known resolves to .direct")
        func autoFallbackWithKnown() throws {
            let mode: IO.File.Direct.Mode = .auto(policy: .fallbackToBuffered)
            let requirements = IO.File.Direct.Requirements(uniformAlignment: 4096)

            let result = try mode.resolve(given: requirements)
            #expect(result == .direct)
        }

        @Test("Linux/Windows: .auto(.errorOnViolation) with .unknown throws")
        func autoErrorWithUnknownThrows() {
            let mode: IO.File.Direct.Mode = .auto(policy: .errorOnViolation)
            let requirements: IO.File.Direct.Requirements = .unknown(reason: .sectorSizeUndetermined)

            #expect(throws: IO.File.Direct.Error.notSupported) {
                try mode.resolve(given: requirements)
            }
        }
        #endif
    }
}

// MARK: - Requirements Tests

@Suite("IO.File.Direct.Requirements")
struct DirectRequirementsTests {

    @Suite("Constructors")
    struct ConstructorTests {

        @Test("uniform alignment init creates .known")
        func uniformAlignmentInit() {
            let req = IO.File.Direct.Requirements(uniformAlignment: 4096)

            if case .known(let alignment) = req {
                #expect(alignment.bufferAlignment == 4096)
                #expect(alignment.offsetAlignment == 4096)
                #expect(alignment.lengthMultiple == 4096)
            } else {
                Issue.record("Expected .known")
            }
        }

        @Test("explicit alignment init creates .known")
        func explicitAlignmentInit() {
            let req = IO.File.Direct.Requirements(
                bufferAlignment: 512,
                offsetAlignment: 4096,
                lengthMultiple: 512
            )

            if case .known(let alignment) = req {
                #expect(alignment.bufferAlignment == 512)
                #expect(alignment.offsetAlignment == 4096)
                #expect(alignment.lengthMultiple == 512)
            } else {
                Issue.record("Expected .known")
            }
        }

        @Test("unknown reasons are distinct")
        func unknownReasons() {
            let r1: IO.File.Direct.Requirements = .unknown(reason: .platformUnsupported)
            let r2: IO.File.Direct.Requirements = .unknown(reason: .sectorSizeUndetermined)
            let r3: IO.File.Direct.Requirements = .unknown(reason: .filesystemUnsupported)
            let r4: IO.File.Direct.Requirements = .unknown(reason: .invalidHandle)

            #expect(r1 != r2)
            #expect(r2 != r3)
            #expect(r3 != r4)
        }

        @Test("reason descriptions are meaningful")
        func reasonDescriptions() {
            let reasons: [IO.File.Direct.Requirements.Reason] = [
                .platformUnsupported,
                .sectorSizeUndetermined,
                .filesystemUnsupported,
                .invalidHandle
            ]

            for reason in reasons {
                #expect(!reason.description.isEmpty)
            }
        }
    }

    @Suite("Alignment Validation")
    struct AlignmentValidationTests {

        @Test("isOffsetAligned checks offset alignment")
        func isOffsetAligned() {
            let alignment = IO.File.Direct.Requirements.Alignment(uniform: 4096)

            #expect(alignment.isOffsetAligned(0))
            #expect(alignment.isOffsetAligned(4096))
            #expect(alignment.isOffsetAligned(8192))

            #expect(!alignment.isOffsetAligned(1))
            #expect(!alignment.isOffsetAligned(512))
            #expect(!alignment.isOffsetAligned(4095))
        }

        @Test("isLengthValid checks length multiple")
        func isLengthValid() {
            let alignment = IO.File.Direct.Requirements.Alignment(uniform: 512)

            #expect(alignment.isLengthValid(512))
            #expect(alignment.isLengthValid(1024))
            #expect(alignment.isLengthValid(4096))

            #expect(!alignment.isLengthValid(1))
            #expect(!alignment.isLengthValid(100))
            #expect(!alignment.isLengthValid(513))
        }
    }

    @Suite("Discovery")
    struct DiscoveryTests {

        @Test("requirements(for:) returns valid result")
        func requirementsForPath() {
            let requirements = IO.File.Direct.requirements(for: "/tmp")

            // Platform-dependent result
            #if os(macOS)
            #expect(requirements == .unknown(reason: .platformUnsupported))
            #elseif os(Linux)
            #expect(requirements == .unknown(reason: .sectorSizeUndetermined))
            #endif
        }
    }
}

// MARK: - Handle Error Tests

@Suite("IO.File.Handle.Error")
struct HandleErrorTests {

    @Suite("Error Cases")
    struct ErrorCaseTests {

        @Test("error cases are distinct")
        func errorCasesDistinct() {
            let errors: [IO.File.Handle.Error] = [
                .invalidHandle,
                .endOfFile,
                .interrupted,
                .noSpace,
                .misalignedBuffer(address: 0, required: 4096),
                .misalignedOffset(offset: 0, required: 4096),
                .invalidLength(length: 0, requiredMultiple: 4096),
                .requirementsUnknown,
                .alignmentViolation(operation: "read"),
                .platform(code: 0, message: "test"),
            ]

            for i in 0..<errors.count {
                for j in (i+1)..<errors.count {
                    #expect(errors[i] != errors[j])
                }
            }
        }

        @Test("error descriptions are meaningful")
        func errorDescriptions() {
            let errors: [IO.File.Handle.Error] = [
                .invalidHandle,
                .endOfFile,
                .interrupted,
                .noSpace,
                .misalignedBuffer(address: 0x1000, required: 4096),
                .misalignedOffset(offset: 100, required: 4096),
                .invalidLength(length: 100, requiredMultiple: 4096),
                .requirementsUnknown,
                .alignmentViolation(operation: "write"),
                .platform(code: 42, message: "test error"),
            ]

            for error in errors {
                let desc = error.description
                #expect(!desc.isEmpty)
            }

            // Check specific content
            #expect(IO.File.Handle.Error.invalidHandle.description.contains("Invalid"))
            #expect(IO.File.Handle.Error.endOfFile.description.contains("End"))
            #expect(IO.File.Handle.Error.alignmentViolation(operation: "read").description.contains("read"))
        }
    }

    #if !os(Windows)
    @Suite("POSIX Error Mapping")
    struct POSIXErrorMappingTests {

        @Test("EBADF maps to invalidHandle")
        func ebadfsToInvalidHandle() {
            let error = IO.File.Handle.Error(posixErrno: EBADF, operation: .read)
            #expect(error == .invalidHandle)
        }

        @Test("EINTR maps to interrupted")
        func eintrToInterrupted() {
            let error = IO.File.Handle.Error(posixErrno: EINTR, operation: .read)
            #expect(error == .interrupted)
        }

        @Test("ENOSPC maps to noSpace")
        func enospcToNoSpace() {
            let error = IO.File.Handle.Error(posixErrno: ENOSPC, operation: .write)
            #expect(error == .noSpace)
        }

        @Test("EINVAL maps to alignmentViolation")
        func einvalToAlignmentViolation() {
            let error = IO.File.Handle.Error(posixErrno: EINVAL, operation: .read)

            if case .alignmentViolation(let op) = error {
                #expect(op == "read")
            } else {
                Issue.record("Expected alignmentViolation, got \(error)")
            }
        }

        @Test("unknown errno maps to platform error")
        func unknownToPlatform() {
            // EAGAIN is not explicitly handled
            let error = IO.File.Handle.Error(posixErrno: EAGAIN, operation: .read)

            if case .platform(let code, _) = error {
                #expect(code == EAGAIN)
            } else {
                Issue.record("Expected platform error")
            }
        }
    }
    #endif
}

// MARK: - Integration Tests

#if !os(Windows)
@Suite("IO.File Handle Integration")
struct HandleIntegrationTests {

    @Test("open and close file with buffered mode")
    func openCloseBuffered() throws {
        let content = "Hello, World!"
        let path = makeTempFile(prefix: "handle-test", content: content)
        defer { removeTempFile(path) }

        let options = IO.File.Open.Options(mode: .read)
        let handle = try IO.File.open(path, options: options)

        // Verify handle properties
        #expect(handle.direct == .buffered)

        // Close is consuming, just let it go out of scope
    }

    @Test("read file with buffered mode")
    func readBuffered() throws {
        let content = "Test content for reading"
        let path = makeTempFile(prefix: "handle-read", content: content)
        defer { removeTempFile(path) }

        let handle = try IO.File.open(path, options: .init(mode: .read))

        var buffer = [UInt8](repeating: 0, count: 4096)
        let bytesRead = try buffer.withUnsafeMutableBytes { ptr in
            try handle.read(into: ptr, at: 0)
        }

        #expect(bytesRead == content.count)

        // Verify content matches using C string comparison
        let matches = buffer.withUnsafeBufferPointer { ptr in
            content.withCString { cStr in
                memcmp(ptr.baseAddress, cStr, bytesRead) == 0
            }
        }
        #expect(matches)
    }

    @Test("write file with buffered mode")
    func writeBuffered() throws {
        let path = "/tmp/handle-write-\(getpid())-\(Int.random(in: 0..<Int.max))"
        defer { removeTempFile(path) }

        var options = IO.File.Open.Options(mode: .write)
        options.create = true

        do {
            let handle = try IO.File.open(path, options: options)

            let content = "Written content"
            let bytesWritten = try content.withCString { ptr in
                try [UInt8](content.utf8).withUnsafeBytes { buffer in
                    try handle.write(from: buffer, at: 0)
                }
            }

            #expect(bytesWritten == content.count)
        }

        // Verify by reading back
        let fd = open(path, O_RDONLY)
        #expect(fd >= 0)
        defer { close(fd) }

        var readBuffer = [CChar](repeating: 0, count: 100)
        let readBytes = read(fd, &readBuffer, readBuffer.count)
        #expect(readBytes == 15) // "Written content"
    }

    @Test("open with .auto(.fallbackToBuffered) succeeds")
    func openAutoFallback() throws {
        let content = "Auto fallback test"
        let path = makeTempFile(prefix: "handle-auto", content: content)
        defer { removeTempFile(path) }

        var options = IO.File.Open.Options(mode: .read)
        options.cache = .auto(policy: .fallbackToBuffered)

        let handle = try IO.File.open(path, options: options)

        // On macOS: .uncached, on Linux: .buffered (because requirements unknown)
        #if os(macOS)
        #expect(handle.direct == .uncached)
        #else
        #expect(handle.direct == .buffered)
        #endif
    }

    @Test("read with aligned buffer")
    func readWithAlignedBuffer() throws {
        let pageSize = Kernel.System.pageSize
        let content = String(repeating: "X", count: pageSize)
        let path = makeTempFile(prefix: "handle-aligned", content: content)
        defer { removeTempFile(path) }

        let handle = try IO.File.open(path, options: .init(mode: .read))

        var buffer = try Buffer.Aligned(byteCount: pageSize, alignment: pageSize)
        let bytesRead = try handle.read(into: &buffer, at: 0)

        #expect(bytesRead == pageSize)
    }

    @Test("write with aligned buffer")
    func writeWithAlignedBuffer() throws {
        let pageSize = Kernel.System.pageSize
        let path = "/tmp/handle-aligned-write-\(getpid())-\(Int.random(in: 0..<Int.max))"
        defer { removeTempFile(path) }

        var options = IO.File.Open.Options(mode: .write)
        options.create = true

        do {
            let handle = try IO.File.open(path, options: options)

            var buffer = try Buffer.Aligned.zeroed(byteCount: pageSize, alignment: pageSize)
            buffer.withUnsafeMutableBytes { ptr in
                for i in 0..<pageSize {
                    ptr[i] = UInt8(i % 256)
                }
            }

            let bytesWritten = try handle.write(from: buffer, at: 0)
            #expect(bytesWritten == pageSize)
        }

        // Verify file size
        var statBuf = stat()
        #expect(path.withCString { stat($0, &statBuf) } == 0)
        #expect(Int(statBuf.st_size) == pageSize)
    }

}
#endif

// MARK: - Direct Error Tests

@Suite("IO.File.Direct.Error")
struct DirectErrorTests {

    @Test("error cases exist and are distinct")
    func errorCasesExist() {
        let errors: [IO.File.Direct.Error] = [
            .notSupported,
            .misalignedBuffer(address: 0, required: 4096),
            .misalignedOffset(offset: 0, required: 4096),
            .invalidLength(length: 0, requiredMultiple: 4096),
            .modeChangeFailed,
            .invalidHandle,
            .platform(code: 0, message: "test"),
        ]

        for i in 0..<errors.count {
            for j in (i+1)..<errors.count {
                #expect(errors[i] != errors[j])
            }
        }
    }

    @Test("errors are Sendable")
    func errorsSendable() {
        let error: IO.File.Direct.Error = .notSupported

        Task.detached {
            _ = error
        }
    }
}

// MARK: - Capability Tests

@Suite("IO.File.Direct.Capability")
struct CapabilityTests {

    @Test("capability cases exist")
    func capabilityCasesExist() {
        let alignment = IO.File.Direct.Requirements.Alignment(uniform: 4096)

        let direct = IO.File.Direct.Capability.directSupported(alignment)
        let uncached = IO.File.Direct.Capability.uncachedOnly
        let buffered = IO.File.Direct.Capability.bufferedOnly

        #expect(uncached != buffered)

        // Check supportsDirect
        #expect(direct.supportsDirect)
        #expect(!uncached.supportsDirect)
        #expect(!buffered.supportsDirect)

        // Check supportsBypass (any form of cache bypass)
        // Direct I/O is a form of cache bypass, so it should return true
        #expect(direct.supportsBypass)
        #expect(uncached.supportsBypass)
        #expect(!buffered.supportsBypass)

        // Check alignment property
        #expect(direct.alignment != nil)
        #expect(uncached.alignment == nil)
        #expect(buffered.alignment == nil)
    }
}
