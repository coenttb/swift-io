//
//  IO.Completion.Accept.Result.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 31/12/2025.
//

public import Kernel

extension IO.Completion.Accept {
    /// Result of an accept operation.
    public struct Result: Sendable {
        /// The accepted connection descriptor.
        public let descriptor: Kernel.Descriptor

        /// The peer address (optional, may be nil).
        public let peerAddress: Void?  // Would be Kernel.SocketAddress

        /// Creates an accept result.
        public init(descriptor: Kernel.Descriptor, peerAddress: Void?) {
            self.descriptor = descriptor
            self.peerAddress = peerAddress
        }
    }
}
