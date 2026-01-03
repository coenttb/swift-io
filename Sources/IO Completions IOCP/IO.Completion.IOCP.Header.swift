//
//  IO.Completion.IOCP.Header.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 31/12/2025.
//

#if os(Windows)

    public import Kernel

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
        /// ```
        ///
        /// ## Usage
        ///
        /// ```swift
        /// // On completion:
        /// let headerPtr = Header.from(overlapped: entry.lpOverlapped)
        /// let operationID = headerPtr.pointee.id
        /// ```
        ///
        /// ## Important
        ///
        /// The kernel does NOT populate custom fields in this struct. Bytes
        /// transferred come from `OVERLAPPED_ENTRY.dwNumberOfBytesTransferred`.
        /// Error status must be obtained via `GetOverlappedResult`.
        ///
        /// ## Thread Safety
        ///
        /// Headers are heap-allocated during submission (poll thread) and
        /// deallocated on completion (also poll thread). Single-threaded access.
        public struct Header {
            /// OVERLAPPED must be the FIRST field for container-of to work.
            ///
            /// Windows kernel uses this for async I/O state.
            public var overlapped: OVERLAPPED

            /// The operation ID for correlation.
            public let id: IO.Completion.ID

            /// The operation kind.
            public let kind: IO.Completion.Kind

            /// Creates a header for an operation.
            public init(id: IO.Completion.ID, kind: IO.Completion.Kind) {
                self.overlapped = OVERLAPPED()
                self.id = id
                self.kind = kind
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

#endif  // os(Windows)
