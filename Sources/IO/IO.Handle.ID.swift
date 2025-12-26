//
//  IO.Handle.ID.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 24/12/2025.
//

extension IO.Handle {
    /// A unique identifier for a registered handle.
    ///
    /// IDs are:
    /// - Scoped to a specific executor instance (prevents cross-executor misuse)
    /// - Never reused within an executor's lifetime
    /// - Sendable and Hashable; Codable when CODABLE flag is set
    public struct ID: Hashable, Sendable {
        /// The unique identifier within the executor.
        public let raw: UInt64
        /// The scope identifier (unique per executor instance).
        public let scope: UInt64
    }
}

#if CODABLE
    extension IO.Handle.ID: Codable {}
#endif
