//
//  IO.Completion.Driver.Capabilities.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 31/12/2025.
//

extension IO.Completion.Driver {
    /// Capabilities of a completion backend.
    ///
    /// Different platforms and backends have different capabilities.
    /// This struct allows the runtime to adapt its behavior accordingly.
    ///
    /// ## Usage
    ///
    /// ```swift
    /// let driver = try IO.Completion.Driver.bestAvailable()
    /// if driver.capabilities.supportedKinds.contains(.fsync) {
    ///     // Can use fsync operations
    /// }
    /// if driver.capabilities.batchedSubmission {
    ///     // Can batch multiple submissions before flush
    /// }
    /// ```
    public struct Capabilities: Sendable {
        /// Maximum number of operations that can be submitted before flush.
        ///
        /// - **IOCP**: Effectively unlimited (immediate submission)
        /// - **io_uring**: Ring size (typically 128-4096)
        public let maxSubmissions: Int

        /// Maximum number of completions that can be returned per poll.
        ///
        /// Determines the size of the event buffer to allocate.
        public let maxCompletions: Int

        /// The set of operation kinds supported by this backend.
        ///
        /// Operations not in this set will fail with `.unsupportedKind`.
        public let supportedKinds: IO.Completion.Kind.Set

        /// Whether the backend supports batched submission.
        ///
        /// - `true`: Multiple operations can be queued before flush
        /// - `false`: Each submit immediately goes to the kernel
        ///
        /// - **IOCP**: false (immediate)
        /// - **io_uring**: true (batch until flush)
        public let batchedSubmission: Bool

        /// Whether the backend supports registered/pinned buffers.
        ///
        /// Registered buffers avoid kernel copies on each I/O operation.
        ///
        /// - **io_uring**: true (IORING_REGISTER_BUFFERS)
        /// - **IOCP**: false
        public let registeredBuffers: Bool

        /// Whether the backend supports multishot operations.
        ///
        /// Multishot operations (like multishot accept) can return
        /// multiple completions from a single submission.
        ///
        /// - **io_uring 5.19+**: true (IORING_ACCEPT_MULTISHOT)
        /// - **IOCP**: false
        public let multishot: Bool

        /// Creates a capabilities descriptor.
        public init(
            maxSubmissions: Int,
            maxCompletions: Int,
            supportedKinds: IO.Completion.Kind.Set,
            batchedSubmission: Bool,
            registeredBuffers: Bool,
            multishot: Bool
        ) {
            self.maxSubmissions = maxSubmissions
            self.maxCompletions = maxCompletions
            self.supportedKinds = supportedKinds
            self.batchedSubmission = batchedSubmission
            self.registeredBuffers = registeredBuffers
            self.multishot = multishot
        }
    }
}
