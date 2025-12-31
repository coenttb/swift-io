//
//  IO.Completion.IOCP.Header.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 31/12/2025.
//

#if os(Windows)

import WinSDK

extension IO.Completion.IOCP {
    /// IOCP operation header for container-of pointer recovery.
    ///
    /// On Windows IOCP, the kernel returns an `OVERLAPPED*` pointer on
    /// completion. To recover our operation context, we use the container-of
    /// pattern: `OVERLAPPED` is placed as the **first field** so that the
    /// `OVERLAPPED*` is also a `Header*`.
    ///
    /// ## Memory Layout
    ///
    /// ```
    /// Header (offset 0):
    ///   overlapped: OVERLAPPED  ← returned by GetQueuedCompletionStatus
    ///   id: ID
    ///   kind: Kind
    ///   bytes: UInt32
    ///   error: UInt32
    /// ```
    ///
    /// ## Usage
    ///
    /// ```swift
    /// // On completion:
    /// let header = Header.from(overlapped: entry.lpOverlapped)
    /// let operationID = header.id
    /// ```
    ///
    /// ## Thread Safety
    ///
    /// Headers are created by the submission path and read by the poll path.
    /// The poll thread has exclusive read access after completion.
    public struct Header {
        /// OVERLAPPED must be the FIRST field for container-of to work.
        ///
        /// Windows kernel writes completion status here.
        public var overlapped: OVERLAPPED

        /// The operation ID for correlation.
        public let id: IO.Completion.ID

        /// The operation kind.
        public let kind: IO.Completion.Kind

        /// Number of bytes transferred (set by kernel).
        public var bytes: UInt32

        /// Error code (0 = success, set by kernel/driver).
        public var error: UInt32

        /// Creates a header for an operation.
        public init(id: IO.Completion.ID, kind: IO.Completion.Kind) {
            self.overlapped = OVERLAPPED()
            self.id = id
            self.kind = kind
            self.bytes = 0
            self.error = 0
        }

        /// Recovers a Header pointer from an OVERLAPPED pointer.
        ///
        /// This is safe because `overlapped` is guaranteed to be at offset 0.
        ///
        /// - Parameter overlapped: The OVERLAPPED pointer from completion.
        /// - Returns: The containing Header.
        @inlinable
        public static func from(overlapped: UnsafeMutablePointer<OVERLAPPED>) -> UnsafeMutablePointer<Header> {
            // OVERLAPPED is at offset 0, so the pointer is the same
            return UnsafeMutableRawPointer(overlapped).assumingMemoryBound(to: Header.self)
        }

        /// Gets a pointer to the overlapped field for Win32 APIs.
        @inlinable
        public mutating func overlappedPointer() -> UnsafeMutablePointer<OVERLAPPED> {
            withUnsafeMutablePointer(to: &overlapped) { $0 }
        }
    }
}

// MARK: - Offset Verification

extension IO.Completion.IOCP.Header {
    /// Verifies that OVERLAPPED is at offset 0.
    ///
    /// Called once at startup to catch layout changes at runtime.
    /// In debug builds, this will trap if the assumption is violated.
    @inlinable
    public static func verifyLayout() {
        assert(
            MemoryLayout<Self>.offset(of: \.overlapped) == 0,
            "OVERLAPPED must be at offset 0 for container-of pattern"
        )
    }
}

#endif // os(Windows)
