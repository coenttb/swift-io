//
//  IO.File.Direct Tests.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 30/12/2025.
//

import Kernel
import Testing

@testable import IO_Primitives

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

    /// Cleans up a temp file
    private func removeTempFile(_ path: String) {
        _ = path.withCString { unlink($0) }
    }
#endif

// MARK: - IO.File.Open.Options Tests

@Suite("IO.File.Open.Options")
struct FileOpenOptionsTests {

    @Test("default options")
    func defaultOptions() {
        let options = IO.File.Open.Options()

        #expect(options.mode == .read)
        #expect(options.create == false)
        #expect(options.truncate == false)
        #expect(options.cache == .buffered)
    }

    @Test("options with mode")
    func optionsWithMode() {
        let readOptions = IO.File.Open.Options(mode: .read)
        let writeOptions = IO.File.Open.Options(mode: .write)
        let readWriteOptions = IO.File.Open.Options(mode: [.read, .write])

        #expect(readOptions.mode == .read)
        #expect(writeOptions.mode == .write)
        #expect(readWriteOptions.mode == [.read, .write])
    }

    @Test("options cache modes")
    func optionsCacheModes() {
        var options = IO.File.Open.Options()

        options.cache = .buffered
        #expect(options.cache == .buffered)

        options.cache = .auto(policy: .fallbackToBuffered)
        #expect(options.cache == .auto(policy: .fallbackToBuffered))
    }
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
                let bytesWritten = try content.withCString { _ in
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
            #expect(readBytes == 15)  // "Written content"
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
    }
#endif
