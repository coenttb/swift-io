//
//  IO.NonBlocking.Driver.Capabilities.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 28/12/2025.
//

extension IO.NonBlocking.Driver {
    /// Capabilities of a selector backend.
    ///
    /// Different platforms have different capabilities. This struct
    /// allows the runtime to adapt its behavior accordingly.
    public struct Capabilities: Sendable {
        /// Maximum number of events that can be returned per poll.
        ///
        /// This determines the size of the event buffer to allocate.
        public let maxEvents: Int

        /// Whether the backend supports edge-triggered mode.
        ///
        /// - **kqueue**: Yes (`EV_CLEAR`)
        /// - **epoll**: Yes (`EPOLLET`)
        /// - **IOCP**: No (completion-based, not readiness-based)
        ///
        /// Edge-triggered mode requires different handling:
        /// - Must drain all available data on each event
        /// - May need to re-arm after processing
        public let supportsEdgeTriggered: Bool

        /// Whether the backend is completion-based rather than readiness-based.
        ///
        /// - **kqueue/epoll**: No (readiness-based)
        /// - **IOCP**: Yes (completion-based)
        ///
        /// Completion-based systems require an adapter layer to present
        /// a uniform readiness API to the portable runtime.
        public let isCompletionBased: Bool

        /// Creates a capabilities descriptor.
        public init(
            maxEvents: Int,
            supportsEdgeTriggered: Bool,
            isCompletionBased: Bool
        ) {
            self.maxEvents = maxEvents
            self.supportsEdgeTriggered = supportsEdgeTriggered
            self.isCompletionBased = isCompletionBased
        }
    }
}
