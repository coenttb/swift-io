//
//  IO.Completion.Submit.Result.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 31/12/2025.
//

public import IO_Primitives
import Kernel
public import Buffer

extension IO.Completion {
    /// Namespace for submission-related types.
    public enum Submit {}
}

// MARK: - Result

extension IO.Completion.Submit {
    /// The result of submitting an operation to the completion queue.
    ///
    /// This struct carries both the completion event and any owned buffer
    /// back to the caller. It is `~Copyable` because it may own a buffer.
    ///
    /// ## Why a struct instead of a tuple?
    ///
    /// Swift 6 does not support tuples containing `~Copyable` types.
    /// This struct provides the same semantics as `(Event, Buffer.Aligned?)`
    /// while being compatible with move-only types.
    ///
    /// ## Usage
    ///
    /// ```swift
    /// let result = try await queue.submit(operation)
    /// var take = result.take()
    /// let event = take.event
    /// if var buffer = take.buffer() {
    ///     // Use the buffer
    /// }
    /// ```
    public struct Result: ~Copyable, Sendable {
        /// The completion event from the driver.
        public let event: IO.Completion.Event

        /// The owned buffer, if the operation had one.
        ///
        /// For read/write operations, this contains the buffer that was
        /// submitted with the operation. For accept/connect/nop, this is nil.
        @usableFromInline
        var _buffer: Buffer.Aligned?

        /// Creates a submit result.
        ///
        /// - Parameters:
        ///   - event: The completion event.
        ///   - buffer: The owned buffer, if any.
        @inlinable
        public init(event: IO.Completion.Event, buffer: consuming Buffer.Aligned?) {
            self.event = event
            self._buffer = buffer
        }

        /// Consumes the result and returns a take handle for extraction.
        ///
        /// This is the only way to extract the buffer from a submit result.
        /// The result is consumed, and the returned `Take` handle owns the
        /// event and buffer.
        ///
        /// - Returns: A move-only take handle.
        @inlinable
        public consuming func take() -> Take {
            Take(event: event, buffer: _buffer)
        }
    }
}

// MARK: - Take

extension IO.Completion.Submit {
    /// Move-only handle for extracting result components.
    ///
    /// Created by calling `result.take()`. Provides access to the event
    /// and buffer in a way that respects ~Copyable ownership.
    ///
    /// ## Usage
    ///
    /// ```swift
    /// var take = result.take()
    /// let event = take.event
    /// let buffer = take.buffer()  // Extracts and consumes buffer
    /// ```
    public struct Take: ~Copyable, Sendable {
        /// The completion event.
        public let event: IO.Completion.Event

        /// The owned buffer.
        @usableFromInline
        var _buffer: Buffer.Aligned?

        /// Creates a take handle.
        @inlinable
        internal init(event: IO.Completion.Event, buffer: consuming Buffer.Aligned?) {
            self.event = event
            self._buffer = buffer
        }

        /// Whether this take handle has an owned buffer.
        @inlinable
        public var hasBuffer: Bool {
            _buffer != nil
        }

        /// Extracts the buffer, if any.
        ///
        /// After calling this method, `hasBuffer` will return false.
        ///
        /// - Returns: The owned buffer, or nil if there was none.
        @inlinable
        public mutating func buffer() -> Buffer.Aligned? {
            var temp: Buffer.Aligned? = nil
            swap(&_buffer, &temp)
            return temp
        }
    }
}

