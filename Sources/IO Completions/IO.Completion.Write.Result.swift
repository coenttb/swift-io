//
//  IO.Completion.Write.Result.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 31/12/2025.
//

public import Buffer

extension IO.Completion.Write {
    /// Result of a write operation.
    public struct Result: ~Copyable, Sendable {
        /// The buffer that was written.
        public var buffer: Buffer.Aligned

        /// Number of bytes written.
        public let bytesWritten: Int

        /// Creates a write result.
        public init(buffer: consuming Buffer.Aligned, bytesWritten: Int) {
            self.buffer = buffer
            self.bytesWritten = bytesWritten
        }
    }
}
