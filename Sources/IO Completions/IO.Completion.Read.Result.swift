//
//  IO.Completion.Read.Result.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 31/12/2025.
//

public import Buffer

extension IO.Completion.Read {
    /// Result of a read operation.
    public struct Result: ~Copyable, Sendable {
        /// The buffer containing the read data.
        public var buffer: Buffer.Aligned

        /// Number of bytes read.
        public let bytesRead: Int

        /// Creates a read result.
        public init(buffer: consuming Buffer.Aligned, bytesRead: Int) {
            self.buffer = buffer
            self.bytesRead = bytesRead
        }
    }
}
