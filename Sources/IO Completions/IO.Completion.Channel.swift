//
//  IO.Completion.Channel.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 31/12/2025.
//

public import Buffer
public import Kernel

extension IO.Completion {
    /// A thin wrapper over Queue for socket-oriented I/O.
    ///
    /// Channel provides a convenient API for common socket operations:
    /// - `read`: Read data into a buffer
    /// - `write`: Write data from a buffer
    /// - `accept`: Accept a new connection
    /// - `connect`: Connect to a remote address
    /// - `close`: Close the channel
    ///
    /// ## Ownership
    ///
    /// Channel is move-only (`~Copyable`) to prevent:
    /// - Multiple channels on the same descriptor
    /// - Use-after-close bugs
    ///
    /// ## Buffer Ownership
    ///
    /// Buffers are consumed on submission and returned on completion:
    /// ```swift
    /// var buffer = try Buffer.Aligned(byteCount: 4096, alignment: 4096)
    /// var result = try await channel.read(into: buffer)
    /// // result.buffer contains the data
    /// ```
    ///
    /// ## Thread Safety
    ///
    /// Channel is `Sendable`. The underlying Queue (an actor) serializes
    /// all operations.
    public struct Channel: ~Copyable, Sendable {
        /// The completion queue.
        let queue: Queue

        /// The underlying descriptor.
        public let descriptor: Kernel.Descriptor

        /// Creates a channel wrapping a descriptor.
        ///
        /// - Parameters:
        ///   - descriptor: The socket descriptor.
        ///   - queue: The completion queue to use.
        public init(descriptor: Kernel.Descriptor, queue: Queue) {
            self.descriptor = descriptor
            self.queue = queue
        }

        // MARK: - Read

        /// Reads data from the channel into a buffer.
        ///
        /// - Parameters:
        ///   - buffer: The buffer to read into (ownership transferred).
        ///   - offset: File offset for positioned read, or `nil` for stream.
        /// - Returns: The read result with buffer and byte count.
        /// - Throws: On I/O error or cancellation.
        public mutating func read(
            into buffer: consuming Buffer.Aligned,
            offset: Int64? = nil
        ) async throws(Failure) -> Read.Result {
            let id = await queue.id.next()
            let operation = Operation.read(
                from: descriptor,
                into: buffer,
                offset: offset,
                id: id
            )

            var take = try await queue.submit(operation).take()
            let event = take.event

            guard var buffer = take.buffer() else {
                throw .failure(.operation(.invalidSubmission))
            }

            let bytesRead: Int
            switch event.outcome {
            case .success(.bytes(let n)):
                bytesRead = n
            case .success:
                bytesRead = 0
            case .failure(let error):
                throw .failure(.kernel(error))
            case .cancellation:
                throw .cancellation
            }

            return Read.Result(buffer: buffer, bytesRead: bytesRead)
        }

        // MARK: - Write

        /// Writes data from a buffer to the channel.
        ///
        /// - Parameters:
        ///   - buffer: The buffer to write from (ownership transferred).
        ///   - offset: File offset for positioned write, or `nil` for stream.
        /// - Returns: The write result with buffer and byte count.
        /// - Throws: On I/O error or cancellation.
        public mutating func write(
            from buffer: consuming Buffer.Aligned,
            offset: Int64? = nil
        ) async throws(Failure) -> Write.Result {
            let id = await queue.id.next()
            let operation = Operation.write(
                to: descriptor,
                from: buffer,
                offset: offset,
                id: id
            )

            var take = try await queue.submit(operation).take()
            let event = take.event

            guard var buffer = take.buffer() else {
                throw .failure(.operation(.invalidSubmission))
            }

            let bytesWritten: Int
            switch event.outcome {
            case .success(.bytes(let n)):
                bytesWritten = n
            case .success:
                bytesWritten = 0
            case .failure(let error):
                throw .failure(.kernel(error))
            case .cancellation:
                throw .cancellation
            }

            return Write.Result(buffer: buffer, bytesWritten: bytesWritten)
        }

        // MARK: - Accept

        /// Accepts a new connection on a listening socket.
        ///
        /// - Returns: The accepted connection result.
        /// - Throws: On I/O error or cancellation.
        public mutating func accept() async throws(Failure) -> Accept.Result {
            let id = await queue.id.next()
            let operation = Operation.accept(from: descriptor, id: id)

            let take = try await queue.submit(operation).take()

            switch take.event.outcome {
            case .success(.accepted(let newDescriptor)):
                return Accept.Result(
                    descriptor: newDescriptor,
                    peerAddress: nil  // Address retrieval is v2
                )
            case .success:
                throw .failure(.operation(.invalidSubmission))
            case .failure(let error):
                throw .failure(.kernel(error))
            case .cancellation:
                throw .cancellation
            }
        }

        // MARK: - Connect

        /// Connects to a remote address.
        ///
        /// - Returns: The connect result.
        /// - Throws: On I/O error or cancellation.
        ///
        /// - Note: Address is not yet supported. This is a placeholder.
        public mutating func connect() async throws(Failure) -> Connect.Result {
            let id = await queue.id.next()
            let operation = Operation.connect(descriptor: descriptor, id: id)

            let take = try await queue.submit(operation).take()

            switch take.event.outcome {
            case .success(.connected):
                return Connect.Result()
            case .success:
                throw .failure(.operation(.invalidSubmission))
            case .failure(let error):
                throw .failure(.kernel(error))
            case .cancellation:
                throw .cancellation
            }
        }

        // MARK: - Close

        /// Closes the channel.
        ///
        /// After calling close, the channel should not be used.
        public consuming func close() async throws(Failure) {
            // In a real implementation, this would submit a close operation
            // For now, we just drop the channel
        }
    }
}

