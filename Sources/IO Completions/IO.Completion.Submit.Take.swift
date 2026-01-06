//
//  IO.Completion.Submit.Take.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 31/12/2025.
//

public import Buffer

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
